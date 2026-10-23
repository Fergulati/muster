//! The private posture's executor as a library function (docs/design/lez-msig.md §6): one JSON
//! request in, one JSON answer out. `bin/msig_exec` (stdin/stdout) and the Logos module
//! `lez_msig_module` both call `exec_request`, so the CLI and the module cannot drift.
//!
//! Requests: {"mode":"derive"|"exec"|"fund", ...}; see `bin/msig_exec.rs` for each field.
//! Answers: the mode's result, or {"error","detail"}.

use std::collections::HashMap;
use std::time::Instant;

use common::transaction::LeeTransaction;
use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::privacy_preserving_transaction::{message::Message as PpMessage, witness_set::WitnessSet as PpWitnessSet};
use lee::PublicKey;
use lee_core::{
    account::{Account, AccountId, Nonce, ProgramShardSelector},
    Commitment,
};
use msig_core::Instruction;
use sequencer_service_rpc::{RpcClient as _, SequencerClientBuilder};
use serde_json::{json, Value};

use crate::{program, Msig};

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

/// The note's membership proof, and the commitment-set root it was read against: the root is
/// what the proof commits to, so muster records it as an external read (invariant 10).
async fn proof_for(rpc: &str, m: &Msig, pre: &Account) -> Result<(lee_core::MembershipProof, String), String> {
    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
    let c = Commitment::new(&m.account(), pre);
    let (proofs, root) = client.get_proofs_and_root(vec![c]).await.map_err(|e| format!("getProofsAndRoot: {e}"))?;
    let root = hex::encode(borsh::to_vec(&root).map_err(|e| e.to_string())?);
    let proof = proofs.into_iter().next().flatten()
        .ok_or_else(|| "the chain holds no commitment for that note: it is stale or was never sent".to_string())?;
    Ok((proof, root))
}

async fn send(rpc: &str, tx: LeeTransaction) -> Result<String, String> {
    let client = SequencerClientBuilder::default().build(rpc).map_err(|e| e.to_string())?;
    let hash = client.send_transaction(tx).await.map_err(|e| format!("sendTransaction: {e}"))?;
    Ok(hex::encode(hash.as_ref() as &[u8]))
}

async fn run(req: Value) -> Result<Value, String> {
    let mode = req.get("mode").and_then(Value::as_str).unwrap_or("exec");
    if mode == "send" {
        return send_signed(&req).await;
    }
    let m = msig_of(&req)?;
    if mode == "derive" {
        return Ok(json!({"account": hex::encode(m.account().as_ref() as &[u8])}));
    }
    let rpc = req.get("rpc").and_then(Value::as_str).ok_or("missing rpc")?.to_string();
    let pre: Option<Account> = match bytes(&req, "pre")? {
        None => None,
        Some(b) => Some(borsh::from_slice(&b).map_err(|e| format!("pre: {e}"))?),
    };
    let (pre_with_proof, root) = match &pre {
        None => (None, String::new()),
        Some(a) => {
            let (proof, root) = proof_for(&rpc, &m, a).await?;
            (Some((a.clone(), proof)), root)
        }
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
                      "account": hex::encode(m.account().as_ref() as &[u8]), "root": root, "proveMs": prove_ms}))
        }
        "fund" => {
            // a deposit into the vault: a native transfer from the payer's public account,
            // proved here and signed by the payer's own key, which never comes here. The answer
            // carries the message's hash to sign; `send` carries the signature back.
            let (pre, proof) = pre_with_proof.ok_or("fund needs the multisig's current note")?;
            let payer_key = PublicKey::try_new(h32(&req, "payerKey")?).map_err(|e| format!("payerKey: {e:?}"))?;
            let payer = AccountId::from(&payer_key);
            let amount: u128 = req.get("amount").and_then(Value::as_str).ok_or("missing amount")?.parse().map_err(|e| format!("amount: {e}"))?;
            let nonce: u128 = req.get("payerNonce").and_then(Value::as_str).unwrap_or("0").parse().map_err(|e| format!("payerNonce: {e}"))?;
            let t = Instant::now();
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
            .map_err(|e| format!("proving the deposit: {e:?}"))?;
            let prove_ms = t.elapsed().as_millis();
            let post = m.decrypt_post(&output).ok_or("the deposit's notes do not decrypt to the multisig's account")?;
            let msg = PpMessage::from_circuit_output(vec![Nonce(nonce)], output);
            Ok(json!({"sign": hex::encode(msg.hash()), "payer": hex::encode(payer.as_ref() as &[u8]),
                      "message": hex::encode(borsh::to_vec(&msg).map_err(|e| e.to_string())?),
                      "proof": hex::encode(borsh::to_vec(&receipt).map_err(|e| e.to_string())?),
                      "post": hex::encode(borsh::to_vec(&post).unwrap()),
                      "account": hex::encode(m.account().as_ref() as &[u8]), "root": root, "proveMs": prove_ms}))
        }
        other => Err(format!("unknown mode {other}")),
    }
}


/// A proved message, signed by its signers elsewhere, sent: {rpc, message, proof,
/// witnesses: [{signature, publicKey}]} → {hash}. Every signature is checked against the
/// message's hash before anything is sent.
async fn send_signed(req: &Value) -> Result<Value, String> {
    let rpc = req.get("rpc").and_then(Value::as_str).ok_or("missing rpc")?;
    let msg: PpMessage = borsh::from_slice(&bytes(req, "message")?.ok_or("missing message")?).map_err(|e| format!("message: {e}"))?;
    let proof: lee::privacy_preserving_transaction::circuit::Proof =
        borsh::from_slice(&bytes(req, "proof")?.ok_or("missing proof")?).map_err(|e| format!("proof: {e}"))?;
    let mut sigs = Vec::new();
    for w in req.get("witnesses").and_then(Value::as_array).ok_or("missing witnesses")? {
        let sig = bytes(w, "signature")?.ok_or("missing signature")?;
        let value: [u8; 64] = sig.try_into().map_err(|_| "a signature is 64 bytes".to_string())?;
        let pk = PublicKey::try_new(h32(w, "publicKey")?).map_err(|e| format!("publicKey: {e:?}"))?;
        sigs.push((lee::Signature { value }, pk));
    }
    let ws = PpWitnessSet::from_raw_parts(sigs, proof);
    if !ws.signatures_are_valid_for(&msg) {
        return Err("bad-signature: a witness does not sign this message".into());
    }
    let hash = send(rpc, LeeTransaction::PrivacyPreserving(lee::privacy_preserving_transaction::PrivacyPreservingTransaction::new(msg, ws))).await?;
    Ok(json!({"hash": hash}))
}

/// Run one request; never panics on input: a bad request or a refusal is {"error","detail"}.
pub async fn exec_request(req: Value) -> Value {
    match run(req).await {
        Ok(v) => v,
        Err(e) => {
            let refused = REFUSALS.iter().any(|c| e.contains(c));
            json!({"error": if refused { "refused" } else { "failed" }, "detail": e})
        }
    }
}

/// The program's refusal codes (msig_core::MsigError): a request the program refused, as
/// opposed to one that failed to reach the chain.
const REFUSALS: &[&str] = &["below-threshold", "stale-epoch", "nonce-spent", "bad-signature", "wrong-account",
    "not-initialised", "needs-queue", "too-early", "expired", "invalid-config", "proposer-did-not-sign", "over-limit",
    "duplicate-signer", "not-a-member", "missing-role", "executor-required", "action-not-allowed", "wrong-rows"];
