//! The program on LEE's own v0.3 state machine (`V03State`), no sequencer: public posture end to
//! end, and the private posture over a group-owned private PDA. Private proofs are dev-mode
//! receipts here (`RISC0_DEV_MODE=1`, set below); real proving is the benchmark's job (exo-b58).
//!
//! What it holds, beyond msig_core's own tests:
//! - the plan's account check: a state at any account but the PDA of its placement is refused
//!   (the counterfeit-state defence), and so is a wrong placement;
//! - not drainable before initialisation (RFP S.7): funds sent before Create stay put;
//! - value leaves only through apply's checks: below threshold, nothing moves;
//! - windows: a time-locked action lands only from its ETA, an expired one never;
//! - the private posture: create, fund, and pay out of a private PDA, decrypting the state as a
//!   member would.

use std::collections::HashMap;

use key_protocol::key_management::group_key_holder::GroupKeyHolder;
use lee::{PrivateKey, PublicKey, V03State};
use lee_core::{account::AccountId, Commitment};
use msig_core::sign::Signer;
use msig_core::*;
use msig_host::{program, vault_balance, Msig, Placement};

const ZONE: Key = [0x2e; 32];

fn dev_mode() {
    std::env::set_var("RISC0_DEV_MODE", "1");
}

fn random_key() -> Key {
    rand::random()
}

fn config(s: &[Signer], k: u32, timelock_ms: u64) -> Config {
    Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: k,
        timelock_ms,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    }
}

fn proposal(m: &Msig, s: &[Signer], epoch: u64, nonce: u64, action: Action) -> Proposal {
    Proposal { multisig: m.key(), zone: ZONE, epoch, nonce, action, expires_ms: 1_000_000, proposer: s[0].key() }
}

fn execute(p: &Proposal, s: &[Signer], who: &[usize]) -> Instruction {
    Instruction::Execute { proposal: p.clone(), approvals: who.iter().map(|&i| s[i].approve(p)).collect(), executor: None }
}

fn refused<T: std::fmt::Debug>(r: Result<T, lee::error::LeeError>, code: &str) {
    let e = format!("{:?}", r.expect_err("expected the program to refuse"));
    assert!(e.contains(code), "expected `{code}` in the refusal, got: {e}");
}

struct Pub {
    state: V03State,
    m: Msig,
    s: Vec<Signer>,
}

fn public_setup(k: u32, timelock_ms: u64, prefund: u128) -> Pub {
    let prog = program();
    let image = prog.id();
    let p = AccountId::from_builtin_program(image);
    let m = Msig::public(p, image, random_key());
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let mut state = V03State::new().with_programs([prog]).with_public_account_balances([(m.account(), prefund)]);
    let create = m.public_tx(Instruction::Create { zone: ZONE, config: config(&s, k, timelock_ms) }, &[]);
    state.transition_from_public_transaction(&create, 1, 0).expect("create");
    Pub { state, m, s }
}

#[test]
fn public_create_then_pay_two_of_three() {
    let mut t = public_setup(2, 0, 1000);
    let a = t.state.get_account_by_id(t.m.account());
    let st = t.m.state_of(&a).expect("the state shard");
    assert_eq!((st.epoch, st.config.threshold, st.create_key), (0, 2, t.m.create_key));
    assert_eq!(vault_balance(&a), 1000, "funds sent before create are still there");

    let to = AccountId::new([0x0e; 32]);
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: msig_v03::key_of(&to), amount: 300 });
    refused(t.state.transition_from_public_transaction(&t.m.public_tx(execute(&p, &t.s, &[0]), &[]), 2, 10), "below-threshold");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 1000, "nothing moved");

    t.state.transition_from_public_transaction(&t.m.public_tx(execute(&p, &t.s, &[0, 1]), &[]), 2, 10).expect("2 of 3");
    assert_eq!(vault_balance(&t.state.get_account_by_id(t.m.account())), 700);
    assert_eq!(vault_balance(&t.state.get_account_by_id(to)), 300);
    refused(t.state.transition_from_public_transaction(&t.m.public_tx(execute(&p, &t.s, &[0, 1]), &[]), 3, 20), "nonce-spent");
}

#[test]
fn nothing_moves_before_create() {
    let prog = program();
    let image = prog.id();
    let m = Msig::public(AccountId::from_builtin_program(image), image, random_key());
    let s: Vec<Signer> = (0..1).map(|_| Signer::random()).collect();
    let mut state = V03State::new().with_programs([prog]).with_public_account_balances([(m.account(), 500)]);
    let p = proposal(&m, &s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 500 });
    refused(state.transition_from_public_transaction(&m.public_tx(execute(&p, &s, &[0]), &[]), 1, 0), "not-initialised");
    assert_eq!(vault_balance(&state.get_account_by_id(m.account())), 500);
}

#[test]
fn a_state_anywhere_but_its_pda_is_refused() {
    let mut t = public_setup(1, 0, 1000);
    // The same create key, claimed to be a private PDA: the plan derives another account, and
    // the transaction's first row (the public PDA) no longer matches.
    let group = GroupKeyHolder::new();
    let fake = Msig::private(t.m.program, t.m.image, t.m.create_key, &group);
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 1 });
    // The real multisig's rows, around an envelope naming the other placement.
    let forged = fake.envelope(execute(&p, &t.s, &[0]));
    let msg = lee::public_transaction::Message::try_new(t.m.program, t.m.selectors(&execute(&p, &t.s, &[0])), vec![], forged).unwrap();
    let tx = lee::PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[]));
    refused(t.state.transition_from_public_transaction(&tx, 2, 0), "wrong-account");

    // A counterfeit multisig: a member's own public account holding a State that names the
    // real create key. Create there is refused: the account is not the PDA.
    let key = PrivateKey::try_new([7; 32]).unwrap();
    let own = AccountId::from(&PublicKey::new_from_private_key(&key));
    let ins = msig_v03::ProgramInstruction {
        create_key: t.m.create_key,
        placement: Placement::Public,
        op: Instruction::Create { zone: ZONE, config: config(&t.s, 1, 0) },
    };
    let msg = lee::public_transaction::Message::try_new(
        t.m.program,
        vec![lee_core::account::ProgramShardSelector::new(own, t.m.program)],
        vec![lee_core::account::Nonce(0)],
        ins,
    )
    .unwrap();
    let tx = lee::PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[&key]));
    refused(t.state.transition_from_public_transaction(&tx, 2, 0), "wrong-account");
}

#[test]
fn rows_must_be_the_outflows_own() {
    let mut t = public_setup(1, 0, 1000);
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 10 });
    let ins = execute(&p, &t.s, &[0]);
    let mut rows = t.m.selectors(&ins);
    rows[2] = lee_core::account::ProgramShardSelector::native_balance(AccountId::new([0x0f; 32])); // another payee
    let msg = lee::public_transaction::Message::try_new(t.m.program, rows, vec![], t.m.envelope(ins)).unwrap();
    let tx = lee::PublicTransaction::new(msg.clone(), lee::public_transaction::WitnessSet::for_message(&msg, &[]));
    refused(t.state.transition_from_public_transaction(&tx, 2, 0), "wrong-rows");
}

#[test]
fn time_lock_lands_from_its_eta_and_never_after_expiry() {
    let mut t = public_setup(2, 1_000, 1000);
    let to = [0x0e; 32];
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to, amount: 50 });
    refused(t.state.transition_from_public_transaction(&t.m.public_tx(execute(&p, &t.s, &[0, 1]), &[]), 2, 10), "needs-queue");
    let q = Instruction::Queue { proposal: p.clone(), approvals: vec![t.s[0].approve(&p), t.s[1].approve(&p)], executor: None, at_ms: 100 };
    // The queue transaction must land no later than its at_ms.
    assert!(t.state.transition_from_public_transaction(&t.m.public_tx(q.clone(), &[]), 2, 101).is_err(), "late queue");
    t.state.transition_from_public_transaction(&t.m.public_tx(q, &[]), 2, 100).expect("queued");
    let st = t.m.state_of(&t.state.get_account_by_id(t.m.account())).unwrap();
    assert_eq!(st.queue[0].eta_ms, 1_100);

    let early = Instruction::ExecuteQueued { proposal: p.clone(), executor: None, at_ms: 1_099 };
    refused(t.state.transition_from_public_transaction(&t.m.public_tx(early, &[]), 3, 1_099), "too-early");
    let ok = Instruction::ExecuteQueued { proposal: p.clone(), executor: None, at_ms: 1_100 };
    // Claiming the ETA but landing before it: the window refuses.
    assert!(t.state.transition_from_public_transaction(&t.m.public_tx(ok.clone(), &[]), 3, 1_050).is_err());
    t.state.transition_from_public_transaction(&t.m.public_tx(ok, &[]), 3, 1_200).expect("at or after the ETA");
    assert_eq!(vault_balance(&t.state.get_account_by_id(AccountId::new(to))), 50);
}

#[test]
fn r2_on_chain() {
    let mut t = public_setup(2, 0, 1000);
    let p = proposal(&t.m, &t.s, 0, 0, Action::Transfer { to: [0x0e; 32], amount: 1 });
    let approved = execute(&p, &t.s, &[0, 1]); // gathered under epoch 0
    let newbie = Signer::random();
    let add = proposal(&t.m, &t.s, 0, 1, Action::Config(vec![ConfigChange::AddMember(Member { key: newbie.key(), roles: role::ALL, weight: 1 })]));
    t.state.transition_from_public_transaction(&t.m.public_tx(execute(&add, &t.s, &[0, 1]), &[]), 2, 0).expect("config change");
    refused(t.state.transition_from_public_transaction(&t.m.public_tx(approved, &[]), 3, 0), "stale-epoch");
}

#[test]
fn spending_limit_on_chain() {
    let mut t = public_setup(3, 0, 1000);
    let lim = SpendingLimit { id: 1, signers: vec![t.s[2].key()], threshold: 1, amount: 100, period_ms: 86_400_000 };
    let add = proposal(&t.m, &t.s, 0, 0, Action::Config(vec![ConfigChange::AddLimit(lim)]));
    t.state.transition_from_public_transaction(&t.m.public_tx(execute(&add, &t.s, &[0, 1, 2]), &[]), 2, 0).expect("limit");
    let sp = Spend { multisig: t.m.key(), zone: ZONE, epoch: 1, limit: 1, nonce: 1, to: [0x0e; 32], amount: 80, expires_ms: 1_000_000 };
    let ins = Instruction::Spend { spend: sp.clone(), approvals: vec![t.s[2].spend(&sp)], period: 0, period_ms: 86_400_000 };
    t.state.transition_from_public_transaction(&t.m.public_tx(ins, &[]), 3, 5).expect("one signer, under the limit");
    assert_eq!(vault_balance(&t.state.get_account_by_id(AccountId::new([0x0e; 32]))), 80);
    let sp2 = Spend { nonce: 2, amount: 21, ..sp };
    let ins = Instruction::Spend { spend: sp2.clone(), approvals: vec![t.s[2].spend(&sp2)], period: 0, period_ms: 86_400_000 };
    refused(t.state.transition_from_public_transaction(&t.m.public_tx(ins, &[]), 4, 6), "over-limit");
}

// ── the private posture ─────────────────────────────────────────────────────────

#[test]
fn private_create_fund_and_pay() {
    dev_mode();
    let prog = program();
    let image = prog.id();
    let p = AccountId::from_builtin_program(image);
    let group = GroupKeyHolder::new();
    let m = Msig::private(p, image, random_key(), &group);
    let a = m.account();
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();

    let funder_key = PrivateKey::try_new([9; 32]).unwrap();
    let funder = AccountId::from(&PublicKey::new_from_private_key(&funder_key));
    let mut state = V03State::new().with_programs([prog]).with_public_account_balances([(funder, 5_000)]);

    // Create: the private PDA's Init, its state written into the program's shard.
    let (tx, post) = m.private_tx(Instruction::Create { zone: ZONE, config: config(&s, 2, 0) }, None, vec![], HashMap::new()).expect("prove create");
    state.transition_from_privacy_preserving_transaction(&tx, 1, 0).expect("create");
    let mut acct = post.expect("the member decrypts the new note");
    assert_eq!(m.state_of(&acct).unwrap().config.threshold, 2);
    assert!(state.get_proof_for_commitment(&Commitment::new(&a, &acct)).is_some(), "the chain holds its commitment");

    // Fund: a public account pays the private PDA (a shield). A member, holding the group's
    // keys, builds it.
    let fund = lee_core::native_token::Instruction::Transfer { amount: 1_000 };
    let proof = state.get_proof_for_commitment(&Commitment::new(&a, &acct)).unwrap();
    let (output, receipt) = lee::execute_and_prove(
        lee::ProvingInput {
            shard_selectors: vec![
                lee_core::account::ProgramShardSelector::native_balance(funder),
                lee_core::account::ProgramShardSelector::native_balance(a),
            ],
            signers: [funder].into(),
            private_witnesses: vec![m.witness(Some((acct.clone(), proof)))],
            instruction_data: lee::program::Program::serialize_instruction(fund).unwrap(),
            dummy_inputs: vec![],
            ciphertext_padding: Some(1024),
        },
        &lee::privacy_preserving_transaction::circuit::ProgramWithDependencies::native(),
    )
    .expect("prove the shield");
    acct = m.decrypt_post(&output).expect("the funded note");
    let msg = lee::privacy_preserving_transaction::message::Message::from_circuit_output(vec![lee_core::account::Nonce(0)], output);
    let ws = lee::privacy_preserving_transaction::witness_set::WitnessSet::for_message(&msg, receipt, &[&funder_key]);
    state.transition_from_privacy_preserving_transaction(&lee::privacy_preserving_transaction::PrivacyPreservingTransaction::new(msg, ws), 2, 0).expect("shield");
    assert_eq!(vault_balance(&acct), 1_000);

    // Pay a public recipient, 2 of 3: the program verifies both approvals inside the proof.
    let to = AccountId::new([0x0e; 32]);
    let pay = Proposal { multisig: m.key(), zone: ZONE, epoch: 0, nonce: 0, action: Action::Transfer { to: msig_v03::key_of(&to), amount: 400 }, expires_ms: 1_000_000, proposer: s[0].key() };
    let below = m.private_tx(execute(&pay, &s, &[0]), Some((acct.clone(), state.get_proof_for_commitment(&Commitment::new(&a, &acct)).unwrap())), vec![], HashMap::new());
    assert!(format!("{:?}", below.expect_err("below threshold cannot even be proven")).contains("below-threshold"));

    let (tx, post) = m
        .private_tx(execute(&pay, &s, &[0, 1]), Some((acct.clone(), state.get_proof_for_commitment(&Commitment::new(&a, &acct)).unwrap())), vec![], HashMap::new())
        .expect("prove the payment");
    state.transition_from_privacy_preserving_transaction(&tx, 3, 10).expect("pay");
    acct = post.unwrap();
    assert_eq!(vault_balance(&acct), 600);
    assert_eq!(vault_balance(&state.get_account_by_id(to)), 400);
    let st = m.state_of(&acct).unwrap();
    assert_eq!(st.nonce_base, 1, "the nonce is spent, inside the private state");
    // On chain, the multisig's account is not a public account: the chain never names it.
    assert_eq!(state.get_account_by_id(a), lee_core::account::Account::default());
}
