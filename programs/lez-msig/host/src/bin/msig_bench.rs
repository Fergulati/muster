//! RFP-005 P.1 / P.2: the private posture's cost with REAL proving (refuses RISC0_DEV_MODE).
//!
//!   cargo run --release -p msig_host --bin msig_bench -- [M ...]      (default: 1 3 5 10)
//!
//! For each M: a fresh multisig of max(M, 3) members with threshold M is created privately, funded,
//! and pays a public recipient with exactly M approvals. The payment is one privacy-preserving
//! transaction: the program verifies M BIP-340 signatures inside its proof. Printed per step: wall
//! time to prove, the transaction's size, and whether the state machine accepted it. The machine
//! and the risc0 version are printed first, so a figure is never quoted without them.

use std::collections::HashMap;
use std::time::Instant;

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, V03State};
use lee_core::{account::AccountId, Commitment};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host::{program, vault_balance, Msig};

const ZONE: Key = [0x2e; 32];

fn main() {
    if std::env::var("RISC0_DEV_MODE").map(|v| v != "0" && !v.is_empty()).unwrap_or(false) {
        eprintln!("refusing: RISC0_DEV_MODE is set; benchmarks are real proofs or nothing (RFP P.1)");
        std::process::exit(2);
    }
    let ms: Vec<usize> = std::env::args().skip(1).filter_map(|a| a.parse().ok()).collect();
    let ms = if ms.is_empty() { vec![1, 3, 5, 10] } else { ms };
    println!("# lez-msig private-posture benchmark (real proving)");
    println!("host: {} cores; risc0-zkvm 3.0.5 (LEZ v0.3.0); prover: {}", std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0), std::env::var("RISC0_PROVER").unwrap_or_else(|_| "default (local CPU)".into()));
    println!();
    println!("| M | step | prove (s) | tx size (bytes) | accepted |");
    println!("|---|---|---|---|---|");
    for m in ms {
        run(m);
    }
}

fn size_of(tx: &lee::privacy_preserving_transaction::PrivacyPreservingTransaction) -> usize {
    borsh::to_vec(tx).map(|b| b.len()).unwrap_or(0)
}

fn run(m: usize) {
    let prog = program();
    let image = prog.id();
    let p = AccountId::from_builtin_program(image);
    let group = GroupKeyHolder::new();
    let ms = Msig::private(p, image, rand_key(), &group);
    let a = ms.account();
    let n = m.max(3);
    let s: Vec<Signer> = (0..n).map(|_| Signer::random()).collect();
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: m as u32,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    };
    let funder_key = PrivateKey::try_new([9; 32]).unwrap();
    let funder = AccountId::from(&PublicKey::new_from_private_key(&funder_key));
    let mut state = V03State::new().with_programs([prog]).with_public_account_balances([(funder, 5_000)]);

    let t = Instant::now();
    let (tx, post) = ms.private_tx(Instruction::Create { zone: ZONE, config }, None, vec![], HashMap::new()).expect("prove create");
    let dt = t.elapsed().as_secs_f64();
    let ok = state.transition_from_privacy_preserving_transaction(&tx, 1, 0).is_ok();
    println!("| {m} | create ({n} members) | {dt:.1} | {} | {ok} |", size_of(&tx));
    let mut acct = post.unwrap();

    let fund = lee_core::native_token::Instruction::Transfer { amount: 1_000 };
    let proof = state.get_proof_for_commitment(&Commitment::new(&a, &acct)).unwrap();
    let t = Instant::now();
    let (output, receipt) = lee::execute_and_prove(
        lee::ProvingInput {
            shard_selectors: vec![
                lee_core::account::ProgramShardSelector::native_balance(funder),
                lee_core::account::ProgramShardSelector::native_balance(a),
            ],
            signers: [funder].into(),
            private_witnesses: vec![ms.witness(Some((acct.clone(), proof)))],
            instruction_data: lee::program::Program::serialize_instruction(fund).unwrap(),
            dummy_inputs: vec![],
            ciphertext_padding: Some(1024),
        },
        &lee::privacy_preserving_transaction::circuit::ProgramWithDependencies::native(),
    )
    .expect("prove the shield");
    let dt = t.elapsed().as_secs_f64();
    acct = ms.decrypt_post(&output).unwrap();
    let msg = lee::privacy_preserving_transaction::message::Message::from_circuit_output(vec![lee_core::account::Nonce(0)], output);
    let ws = lee::privacy_preserving_transaction::witness_set::WitnessSet::for_message(&msg, receipt, &[&funder_key]);
    let tx = lee::privacy_preserving_transaction::PrivacyPreservingTransaction::new(msg, ws);
    let ok = state.transition_from_privacy_preserving_transaction(&tx, 2, 0).is_ok();
    println!("| {m} | fund (shield, native only) | {dt:.1} | {} | {ok} |", size_of(&tx));

    let to = AccountId::new([0x0e; 32]);
    let pay = Proposal { multisig: ms.key(), zone: ZONE, epoch: 0, nonce: 0, action: Action::Transfer { to: msig_v03::key_of(&to), amount: 400 }, expires_ms: 1_000_000, proposer: s[0].key() };
    let approvals = (0..m).map(|i| s[i].approve(&pay)).collect();
    let ins = Instruction::Execute { proposal: pay, approvals, executor: None };
    let proof = state.get_proof_for_commitment(&Commitment::new(&a, &acct)).unwrap();
    let t = Instant::now();
    let (tx, post) = ms.private_tx(ins, Some((acct, proof)), vec![], HashMap::new()).expect("prove the payment");
    let dt = t.elapsed().as_secs_f64();
    let ok = state.transition_from_privacy_preserving_transaction(&tx, 3, 10).is_ok()
        && vault_balance(&post.unwrap()) == 600
        && vault_balance(&state.get_account_by_id(to)) == 400;
    println!("| {m} | **execute: pay, {m} signatures** | **{dt:.1}** | {} | {ok} |", size_of(&tx));
}

fn rand_key() -> Key {
    let mut k = [0u8; 32];
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos().to_le_bytes();
    k[..16].copy_from_slice(&t);
    msig_core::tagged(b"bench", &k)
}
