//! The private posture against a REAL LEZ v0.3 sequencer: create a multisig over a group-owned
//! private PDA, fund it, pay 2-of-3 out of it. Each step is one privacy-preserving transaction
//! the sequencer accepts. Skipped unless MSIG_LIVE_RPC (the zone) and MSIG_LIVE_PROGRAM (the
//! deployed program's account id, hex) name a zone. The test makes a throwaway public key and has
//! the zone's funder pay it (infra/lez/funder.sh), then shields from it:
//!
//!   infra/lez/localnet.sh; infra/lez/localnet.sh deploy <msig.bin>
//!   MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<hex> \
//!     RISC0_DEV_MODE=1 cargo test -p msig_host --test live_private -- --nocapture
//!
//! On the local zone (dev mode) receipts are stubs; against the testnet, real proving.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use common::transaction::LeeTransaction;
use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey};
use lee_core::{
    account::{Account, AccountId, Nonce, ProgramShardSelector},
    Commitment,
};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host::{program, vault_balance, Msig};
use sequencer_service_rpc::{RpcClient as _, SequencerClient, SequencerClientBuilder};

async fn proof(c: &SequencerClient, m: &Msig, a: &Account) -> lee_core::MembershipProof {
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        let (p, _) = c.get_proofs_and_root(vec![Commitment::new(&m.account(), a)]).await.expect("getProofsAndRoot");
        if let Some(Some(p)) = p.into_iter().next() {
            return p;
        }
        assert!(Instant::now() < deadline, "the note never landed");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn private_multisig_on_a_live_zone() {
    let (Ok(rpc), Ok(prog_hex)) = (std::env::var("MSIG_LIVE_RPC"), std::env::var("MSIG_LIVE_PROGRAM")) else {
        eprintln!("skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let c = SequencerClientBuilder::default().build(&rpc).unwrap();
    let program = AccountId::new(hex::decode(prog_hex).unwrap().try_into().unwrap());
    let group = GroupKeyHolder::new();
    let ck: Key = rand::random();
    let m = Msig::private(program, program_elf_id(), ck, &group);
    let a = m.account();
    let zone: Key = tagged(b"muster-msig/v1/zone", b"lez:local");
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };

    // 1. create: the private PDA's Init, from the deployed program
    let (tx, post) = m.private_tx(Instruction::Create { zone, config }, None, vec![], HashMap::new()).expect("prove create");
    c.send_transaction(LeeTransaction::PrivacyPreserving(tx)).await.expect("create accepted");
    let mut acct = post.unwrap();
    let mut pr = proof(&c, &m, &acct).await;
    eprintln!("1. created privately: the chain holds the note's commitment, and no public account at {a}");
    assert_eq!(c.get_account(a).await.unwrap(), Account::default(), "nothing public at the multisig's id");

    // 2. fund: a throwaway public account, paid by the zone's funder, shields into the private PDA
    let key = PrivateKey::try_new(rand::random()).unwrap();
    let funder = AccountId::from(&PublicKey::new_from_private_key(&key));
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../infra/lez/funder.sh");
    let out = std::process::Command::new(script)
        .args(["--zone", &rpc, "fund", &hex::encode(funder.as_ref() as &[u8]), "10000000000"])
        .output()
        .expect("run the zone's funder");
    assert!(out.status.success(), "the funder could not pay: {}", String::from_utf8_lossy(&out.stderr));
    let deadline = Instant::now() + Duration::from_secs(90);
    while c.get_account_balance(funder).await.unwrap() == 0 {
        assert!(Instant::now() < deadline, "the funder's payment never landed");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    let nonce = c.get_accounts_nonces(vec![funder]).await.unwrap()[0];
    let (output, receipt) = lee::execute_and_prove(
        lee::ProvingInput {
            shard_selectors: vec![ProgramShardSelector::native_balance(funder), ProgramShardSelector::native_balance(a)],
            signers: [funder].into(),
            private_witnesses: vec![m.witness(Some((acct.clone(), pr)))],
            instruction_data: lee::program::Program::serialize_instruction(lee_core::native_token::Instruction::Transfer { amount: 5_000 }).unwrap(),
            dummy_inputs: vec![],
            ciphertext_padding: Some(1024),
        },
        &lee::privacy_preserving_transaction::circuit::ProgramWithDependencies::native(),
    )
    .expect("prove the shield");
    acct = m.decrypt_post(&output).unwrap();
    let msg = lee::privacy_preserving_transaction::message::Message::from_circuit_output(vec![nonce], output);
    let ws = lee::privacy_preserving_transaction::witness_set::WitnessSet::for_message(&msg, receipt, &[&key]);
    c.send_transaction(LeeTransaction::PrivacyPreserving(lee::privacy_preserving_transaction::PrivacyPreservingTransaction::new(msg, ws)))
        .await
        .expect("shield accepted");
    pr = proof(&c, &m, &acct).await;
    assert_eq!(vault_balance(&acct), 5_000);
    eprintln!("2. funded: 5000 shielded into the private vault");

    // 3. pay a public recipient, 2 of 3, approvals verified inside the proof
    let to = AccountId::new(rand::random());
    let p = Proposal { multisig: m.key(), zone, epoch: 0, nonce: 0, action: Action::Transfer { to: msig_v03::key_of(&to), amount: 1_200 },
                       expires_ms: u64::MAX / 2, proposer: s[0].key() };
    let below = m.private_tx(Instruction::Execute { proposal: p.clone(), approvals: vec![s[0].approve(&p)], executor: None },
                             Some((acct.clone(), pr.clone())), vec![], HashMap::new());
    assert!(format!("{:?}", below.expect_err("below threshold")).contains("below-threshold"));
    let (tx, post) = m
        .private_tx(Instruction::Execute { proposal: p.clone(), approvals: vec![s[0].approve(&p), s[1].approve(&p)], executor: None },
                    Some((acct.clone(), pr)), vec![], HashMap::new())
        .expect("prove the payment");
    c.send_transaction(LeeTransaction::PrivacyPreserving(tx)).await.expect("payment accepted");
    acct = post.unwrap();
    proof(&c, &m, &acct).await;
    let deadline = Instant::now() + Duration::from_secs(60);
    while c.get_account_balance(to).await.unwrap() != 1_200 {
        assert!(Instant::now() < deadline, "the recipient was never paid");
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    assert_eq!(vault_balance(&acct), 3_800);
    eprintln!("3. paid 1200 to a public recipient, 2 of 3, in one private transaction; the vault holds 3800 privately");
    let _ = Nonce(0);
}

fn program_elf_id() -> lee_core::program::ProgramId {
    program().id()
}
