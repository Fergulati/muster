//! The private posture's executor (docs/design/lez-msig.md §6): one JSON request on stdin, one
//! JSON answer on stdout. Muster builds and signs everything it can (the proposal, the
//! approvals, the instruction's bytes); this proves the program's execution over the
//! multisig's private note and sends it, because proving needs LEZ's own Rust prover.
//!
//! Requests (every hex string lowercase, no 0x):
//!   {"mode":"derive","program","gms","createKey"}
//!       → {"account"}: the multisig's private PDA, which only a holder of the group secret can
//!         derive (its keys are part of the address).
//!   {"mode":"exec","rpc","program","gms","createKey","pre":<Account borsh> | null,"op":<msig_core::Instruction borsh>}
//!       → {"hash","post":<Account borsh>,"account","proveMs"}: proved against the chain's
//!         membership proof for `pre` (null for Create, an Init) and sent. `post` is the new
//!         note in plaintext, as a member decrypts it. Muster carries it, sealed, in the room,
//!         so every member can execute next without scanning the chain.
//!   {"mode":"fund","rpc","program","gms","createKey","pre","payerSecret","payerNonce","amount"}
//!       → {"hash","post"}: DEVELOPMENT ONLY. A shield from a public account whose secret is
//!         passed in. A member's real deposit is signed in their own wallet.
//! Errors: {"error","detail"}. A refusal the program makes surfaces as its MsigError code at
//! proving time, before anything is sent (RFP U.7).
//!
//! `RISC0_DEV_MODE` decides whether proofs are real; a dev-mode zone accepts dev receipts only.

use std::collections::HashMap;
use std::io::Read;
use std::time::Instant;

use common::transaction::LeeTransaction;
use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey};
use lee_core::{
    account::{Account, AccountId, Nonce, ProgramShardSelector},
    Commitment,
};
use msig_core::Instruction;
use msig_host::{program, Msig};
use sequencer_service_rpc::{RpcClient as _, SequencerClientBuilder};
use serde_json::{json, Value};

fn h32(v: &Value, k: &str) -> Result<[u8; 32], String> {
    let s = v.get(k).and_then(Value::as_str).ok_or(format!("missing {k}"))?;
    let b = hex::decode(s).map_err(|e| format!("{k}: {e}"))?;
    b.try_into().map_err(|_| format!("{k} is not 32 bytes"))
}

fn bytes(v: &Value, k: &str) -> Result<Option<Vec<u8>>, String> {
    match v.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => hex::decode(s).map(Some).map_err(|e| format!("{k}: {e}")),
        _ => Err(format!("{k} is not hex")),
    }
}

fn msig_of(req: &Value) -> Result<Msig, String> {
    let program = AccountId::new(h32(req, "program")?);
    let group = GroupKeyHolder::from_gms(h32(req, "gms")?);
    let prog = program_elf();
    Ok(Msig::private(program, prog.id(), h32(req, "createKey")?, &group))
}

fn program_elf() -> lee::program::Program {
    program()
}

async fn proof_for(rpc: &str, m: &Msig, pre: &Account) -> Result<lee_core::MembershipProof, String> {
    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
    let c = Commitment::new(&m.account(), pre);
    let (proofs, _root) = client.get_proofs_and_root(vec![c]).await.map_err(|e| format!("getProofsAndRoot: {e}"))?;
    proofs.into_iter().next().flatten().ok_or("the chain holds no commitment for that note: it is stale or was never sent".into())
}

async fn send(rpc: &str, tx: LeeTransaction) -> Result<String, String> {
    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
    let hash = client.send_transaction(tx).await.map_err(|e| format!("sendTransaction: {e}"))?;
    Ok(hex::encode(hash.as_ref() as &[u8]))
}

async fn run(req: Value) -> Result<Value, String> {
    let mode = req.get("mode").and_then(Value::as_str).unwrap_or("exec");
    let m = msig_of(&req)?;
    if mode == "derive" {
        return Ok(json!({"account": hex::encode(m.account().as_ref() as &[u8])}));
    }
    let rpc = req.get("rpc").and_then(Value::as_str).ok_or("missing rpc")?.to_string();
    let pre: Option<Account> = match bytes(&req, "pre")? {
        None => None,
        Some(b) => Some(borsh::from_slice(&b).map_err(|e| format!("pre: {e}"))?),
    };
    let pre_with_proof = match &pre {
        None => None,
        Some(a) => Some((a.clone(), proof_for(&rpc, &m, a).await?)),
    };
    match mode {
        "exec" => {
            let op: Instruction = borsh::from_slice(&bytes(&req, "op")?.ok_or("missing op")?).map_err(|e| format!("op: {e}"))?;
            let t = Instant::now();
            let (tx, post) = m
                .private_tx(op, pre_with_proof, vec![], HashMap::new())
                .map_err(|e| format!("the program refused it while proving: {e:?}"))?;
            let prove_ms = t.elapsed().as_millis();
            let post = post.ok_or("the proof's notes do not decrypt to the multisig's account")?;
            let hash = send(&rpc, LeeTransaction::PrivacyPreserving(tx)).await?;
            Ok(json!({"hash": hash, "post": hex::encode(borsh::to_vec(&post).unwrap()),
                      "account": hex::encode(m.account().as_ref() as &[u8]), "proveMs": prove_ms}))
        }
        "fund" => {
            let (pre, proof) = pre_with_proof.ok_or("fund needs the multisig's current note")?;
            let key = PrivateKey::try_new(h32(&req, "payerSecret")?).map_err(|e| format!("payerSecret: {e:?}"))?;
            let payer = AccountId::from(&PublicKey::new_from_private_key(&key));
            let amount: u128 = req.get("amount").and_then(Value::as_str).ok_or("missing amount")?.parse().map_err(|e| format!("amount: {e}"))?;
            let nonce: u128 = req.get("payerNonce").and_then(Value::as_str).unwrap_or("0").parse().map_err(|e| format!("payerNonce: {e}"))?;
            let (output, receipt) = lee::execute_and_prove(
                lee::ProvingInput {
                    shard_selectors: vec![ProgramShardSelector::native_balance(payer), ProgramShardSelector::native_balance(m.account())],
                    signers: [payer].into(),
                    private_witnesses: vec![m.witness(Some((pre, proof)))],
                    instruction_data: lee::program::Program::serialize_instruction(lee_core::native_token::Instruction::Transfer { amount })
                        .map_err(|e| format!("{e:?}"))?,
                    dummy_inputs: vec![],
                    ciphertext_padding: Some(1024),
                },
                &lee::privacy_preserving_transaction::circuit::ProgramWithDependencies::native(),
            )
            .map_err(|e| format!("proving the shield: {e:?}"))?;
            let post = m.decrypt_post(&output).ok_or("the shield's notes do not decrypt to the multisig's account")?;
            let msg = lee::privacy_preserving_transaction::message::Message::from_circuit_output(vec![Nonce(nonce)], output);
            let ws = lee::privacy_preserving_transaction::witness_set::WitnessSet::for_message(&msg, receipt, &[&key]);
            let hash = send(&rpc, LeeTransaction::PrivacyPreserving(lee::privacy_preserving_transaction::PrivacyPreservingTransaction::new(msg, ws))).await?;
            Ok(json!({"hash": hash, "post": hex::encode(borsh::to_vec(&post).unwrap())}))
        }
        other => Err(format!("unknown mode {other}")),
    }
}

#[tokio::main]
async fn main() {
    let mut input = String::new();
    let answer = match std::io::stdin().read_to_string(&mut input) {
        Err(e) => json!({"error": "bad-request", "detail": e.to_string()}),
        Ok(_) => match serde_json::from_str::<Value>(&input) {
            Err(e) => json!({"error": "bad-request", "detail": e.to_string()}),
            Ok(req) => match run(req).await {
                Ok(v) => v,
                Err(e) => {
                    let code = e.split(':').find(|w| msig_core_codes().iter().any(|c| w.contains(c))).map(|_| "refused").unwrap_or("failed");
                    json!({"error": code, "detail": e})
                }
            },
        },
    };
    println!("{answer}");
}

fn msig_core_codes() -> &'static [&'static str] {
    &["below-threshold", "stale-epoch", "nonce-spent", "bad-signature", "wrong-account", "not-initialised",
      "needs-queue", "too-early", "expired", "invalid-config", "proposer-did-not-sign", "over-limit"]
}
