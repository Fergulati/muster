//! Every rule of docs/design/lez-msig.md §5, held one test at a time. RFP S.7's minimums:
//! below threshold (`below_threshold_refused`), R.2 (`r2_*`), and not drainable before
//! initialisation (`nothing_before_create`; the adapter holds it again on a chain).

use msig_core::sign::Signer;
use msig_core::*;
use proptest::prelude::*;

const A: Key = [0xaa; 32];
const CK: Key = [0xcc; 32];
const ZONE: Key = [0x2e; 32];
const PROG: Key = [0x99; 32];
const TO: Key = [0x0e; 32];
const CTX: Ctx = Ctx { multisig: A, create_key: CK };

struct M {
    s: Vec<Signer>,
    st: State,
}

fn mem(s: &Signer, roles: u8, weight: u16) -> Member {
    Member { key: s.key(), roles, weight }
}

fn config(s: &[Signer], k: u32) -> Config {
    Config {
        members: s.iter().map(|x| mem(x, role::ALL, 1)).collect(),
        threshold: k,
        timelock_ms: 0,
        open_execution: true,
        actions: action_kind::ALL,
        targets: vec![],
        limits: vec![],
    }
}

fn create(n: usize, k: u32, tweak: impl FnOnce(&mut Config, &[Signer])) -> M {
    let s: Vec<Signer> = (0..n).map(|_| Signer::random()).collect();
    let mut c = config(&s, k);
    tweak(&mut c, &s);
    let st = apply(None, &Instruction::Create { zone: ZONE, config: c }, &CTX, Some(&PROG)).expect("create");
    M { s, st }
}

impl M {
    fn proposal(&self, nonce: u64, action: Action) -> Proposal {
        Proposal {
            multisig: A,
            zone: ZONE,
            epoch: self.st.epoch,
            nonce,
            action,
            expires_ms: 1_000_000,
            proposer: self.s[0].key(),
        }
    }
    fn approvals(&self, p: &Proposal, who: &[usize]) -> Vec<Signed> {
        who.iter().map(|&i| self.s[i].approve(p)).collect()
    }
    fn execute(&mut self, p: &Proposal, who: &[usize]) -> Result<(), MsigError> {
        let ins = Instruction::Execute { proposal: p.clone(), approvals: self.approvals(p, who), executor: None };
        self.st = apply(Some(&self.st), &ins, &CTX, Some(&PROG))?;
        Ok(())
    }
    fn run(&mut self, ins: &Instruction) -> Result<(), MsigError> {
        self.st = apply(Some(&self.st), ins, &CTX, Some(&PROG))?;
        Ok(())
    }
}

fn pay(amount: u128) -> Action {
    Action::Transfer { to: TO, amount }
}

fn code(r: Result<(), MsigError>) -> &'static str {
    r.err().map(|e| e.code()).unwrap_or("ok")
}

// ── creation ───────────────────────────────────────────────────────────────────

#[test]
fn create_writes_state_once() {
    let m = create(3, 2, |_, _| {});
    assert_eq!(m.st.epoch, 0);
    assert_eq!(m.st.create_key, CK);
    let again = Instruction::Create { zone: ZONE, config: m.st.config.clone() };
    assert_eq!(apply(Some(&m.st), &again, &CTX, None).unwrap_err().code(), "already-initialised");
}

#[test]
fn invalid_configs_refused() {
    let s: Vec<Signer> = (0..3).map(|_| Signer::random()).collect();
    let bad = |f: &dyn Fn(&mut Config)| {
        let mut c = config(&s, 2);
        f(&mut c);
        validate_config(&c).unwrap_err().code()
    };
    assert_eq!(bad(&|c| c.threshold = 0), "invalid-config");
    assert_eq!(bad(&|c| c.threshold = 4), "invalid-config");
    assert_eq!(bad(&|c| c.members.clear()), "invalid-config");
    assert_eq!(bad(&|c| c.members[1].key = c.members[0].key), "invalid-config");
    assert_eq!(bad(&|c| c.members[0].weight = 0), "invalid-config");
    assert_eq!(bad(&|c| c.members[0].key = [0; 32]), "invalid-config");
    assert_eq!(bad(&|c| c.members.iter_mut().for_each(|m| m.roles = role::APPROVE)), "invalid-config");
    assert_eq!(bad(&|c| { c.open_execution = false; c.members.iter_mut().for_each(|m| m.roles = role::PROPOSE | role::APPROVE) }), "invalid-config");
    assert_eq!(bad(&|c| c.timelock_ms = MAX_TIMELOCK_MS + 1), "invalid-config");
    assert_eq!(bad(&|c| c.limits.push(SpendingLimit { id: 1, signers: vec![[7; 32]], threshold: 1, amount: 1, period_ms: 1 })), "invalid-config");
    // A threshold above the APPROVE weight: a PROPOSE-only member adds nothing.
    assert_eq!(bad(&|c| { c.members[2].roles = role::PROPOSE; c.threshold = 3 }), "invalid-config");
}

#[test]
fn nothing_before_create() {
    let s = Signer::random();
    let p = Proposal { multisig: A, zone: ZONE, epoch: 0, nonce: 0, action: pay(1), expires_ms: 9, proposer: s.key() };
    let ins = Instruction::Execute { proposal: p.clone(), approvals: vec![s.approve(&p)], executor: None };
    assert_eq!(apply(None, &ins, &CTX, None).unwrap_err().code(), "not-initialised");
}

// ── R.1: approvals ─────────────────────────────────────────────────────────────

#[test]
fn below_threshold_refused() {
    let mut m = create(3, 2, |_, _| {});
    let p = m.proposal(0, pay(5));
    assert_eq!(code(m.execute(&p, &[0])), "below-threshold");
    assert_eq!(code(m.execute(&p, &[0, 1])), "ok");
}

#[test]
fn approvals_must_be_distinct_members_signing_exactly_this() {
    let mut m = create(3, 2, |_, _| {});
    let p = m.proposal(0, pay(5));
    // the same member twice
    let dup = vec![m.s[0].approve(&p), m.s[0].approve(&p)];
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p.clone(), approvals: dup, executor: None })), "duplicate-signer");
    // an outsider
    let out = Signer::random();
    let a = vec![m.s[0].approve(&p), out.approve(&p)];
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p.clone(), approvals: a, executor: None })), "not-a-member");
    // a signature over another proposal (another amount), replayed onto this one
    let other = m.proposal(0, pay(6));
    let a = vec![m.s[0].approve(&p), m.s[1].approve(&other)];
    let bad = Instruction::Execute { proposal: p.clone(), approvals: a, executor: None };
    assert_eq!(code(m.run(&bad)), "bad-signature");
    // a signature over the bare proposal id, not the approve message
    let mut a = m.approvals(&p, &[0]);
    a.push(m.s[1].sign(&proposal_id(&p)));
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p.clone(), approvals: a, executor: None })), "bad-signature");
    // a valid set lands once
    assert_eq!(code(m.execute(&p, &[0, 1])), "ok");
    assert_eq!(code(m.execute(&p, &[0, 1])), "nonce-spent");
}

#[test]
fn the_proposer_must_sign_and_counts_only_if_an_approver() {
    let mut m = create(3, 2, |c, _| c.members[0].roles = role::PROPOSE);
    let p = m.proposal(0, pay(1));
    // proposer missing
    assert_eq!(code(m.execute(&p, &[1, 2])), "proposer-did-not-sign");
    // proposer (PROPOSE only) + one approver: weight 1 < 2
    assert_eq!(code(m.execute(&p, &[0, 1])), "below-threshold");
    assert_eq!(code(m.execute(&p, &[0, 1, 2])), "ok");
    // a proposer without PROPOSE
    let mut m = create(3, 2, |c, _| c.members[0].roles = role::APPROVE | role::EXECUTE);
    let p = m.proposal(0, pay(1));
    assert_eq!(code(m.execute(&p, &[0, 1])), "missing-role");
}

#[test]
fn a_signer_without_approve_is_refused() {
    let mut m = create(3, 1, |c, _| c.members[2].roles = role::EXECUTE);
    let p = m.proposal(0, pay(1));
    assert_eq!(code(m.execute(&p, &[0, 2])), "missing-role");
    assert_eq!(code(m.execute(&p, &[0])), "ok");
}

#[test]
fn weights_count() {
    let mut m = create(3, 3, |c, _| c.members[1].weight = 2);
    let p = m.proposal(0, pay(1));
    assert_eq!(code(m.execute(&p, &[0, 2])), "below-threshold");
    assert_eq!(code(m.execute(&p, &[0, 1])), "ok");
}

#[test]
fn proposal_bound_to_account_zone_and_create_key() {
    let mut m = create(2, 1, |_, _| {});
    let mut p = m.proposal(0, pay(1));
    p.multisig = [1; 32];
    assert_eq!(code(m.execute(&p, &[0])), "wrong-account");
    let mut p = m.proposal(0, pay(1));
    p.zone = [1; 32];
    assert_eq!(code(m.execute(&p, &[0])), "wrong-zone");
    let p = m.proposal(0, pay(1));
    let ins = Instruction::Execute { proposal: p.clone(), approvals: m.approvals(&p, &[0]), executor: None };
    let other = Ctx { multisig: A, create_key: [1; 32] };
    assert_eq!(apply(Some(&m.st), &ins, &other, None).unwrap_err().code(), "wrong-create-key");
}

#[test]
fn executor_role_when_execution_is_closed() {
    let mut m = create(3, 2, |c, _| {
        c.open_execution = false;
        c.members[0].roles = role::PROPOSE | role::APPROVE;
        c.members[1].roles = role::PROPOSE | role::APPROVE;
        c.members[2].roles = role::EXECUTE;
    });
    let p = m.proposal(0, pay(1));
    let a = m.approvals(&p, &[0, 1]);
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p.clone(), approvals: a.clone(), executor: None })), "executor-required");
    let not_exec = Some(m.s[0].execute(&p));
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p.clone(), approvals: a.clone(), executor: not_exec })), "missing-role");
    let wrong_msg = Some(m.s[2].approve(&p));
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p.clone(), approvals: a.clone(), executor: wrong_msg })), "bad-signature");
    let ex = Some(m.s[2].execute(&p));
    assert_eq!(code(m.run(&Instruction::Execute { proposal: p, approvals: a, executor: ex })), "ok");
}

#[test]
fn action_set_and_targets() {
    let mut m = create(2, 1, |c, _| {
        c.actions = action_kind::CALL;
        c.targets = vec![[5; 32]];
    });
    assert_eq!(code(m.execute(&m.proposal(0, pay(1)), &[0])), "action-not-allowed");
    let call = |p: Key| Action::Call { program: p, rows: vec![], data: vec![1] };
    assert_eq!(code(m.execute(&m.proposal(0, call([6; 32])), &[0])), "target-not-allowed");
    assert_eq!(code(m.execute(&m.proposal(0, call(PROG)), &[0])), "calls-own-program");
    assert_eq!(code(m.execute(&m.proposal(0, call([5; 32])), &[0])), "ok");
    // with no target list, the program itself is still refused
    let mut m = create(2, 1, |_, _| {});
    assert_eq!(code(m.execute(&m.proposal(0, call(PROG)), &[0])), "calls-own-program");
}

// ── replay: the nonce window ───────────────────────────────────────────────────

#[test]
fn nonces_any_order_once_inside_the_window() {
    let mut m = create(2, 1, |_, _| {});
    assert_eq!(code(m.execute(&m.proposal(5, pay(1)), &[0])), "ok");
    assert_eq!(m.st.nonce_base, 0);
    assert_eq!(code(m.execute(&m.proposal(0, pay(1)), &[0])), "ok");
    assert_eq!(m.st.nonce_base, 1);
    for n in 1..5 {
        assert_eq!(code(m.execute(&m.proposal(n, pay(1)), &[0])), "ok");
    }
    assert_eq!(m.st.nonce_base, 6);
    assert_eq!(code(m.execute(&m.proposal(3, pay(1)), &[0])), "nonce-spent");
    assert_eq!(code(m.execute(&m.proposal(6 + NONCE_WINDOW, pay(1)), &[0])), "nonce-out-of-window");
    assert_eq!(code(m.execute(&m.proposal(5 + NONCE_WINDOW, pay(1)), &[0])), "ok");
}

// ── time lock, queue, cancel, expiry ───────────────────────────────────────────

fn queue(m: &M, p: &Proposal, who: &[usize], at: u64) -> Instruction {
    Instruction::Queue { proposal: p.clone(), approvals: m.approvals(p, who), executor: None, at_ms: at }
}
fn exq(p: &Proposal, at: u64) -> Instruction {
    Instruction::ExecuteQueued { proposal: p.clone(), executor: None, at_ms: at }
}

#[test]
fn timelock_queue_then_execute_at_eta() {
    let mut m = create(3, 2, |c, _| c.timelock_ms = 100);
    let p = m.proposal(0, pay(1));
    assert_eq!(code(m.execute(&p, &[0, 1])), "needs-queue");
    assert_eq!(code(m.run(&queue(&m, &p, &[0], 10))), "below-threshold");
    assert_eq!(code(m.run(&queue(&m, &p, &[0, 1], 10))), "ok");
    assert_eq!(m.st.queue[0].eta_ms, 110);
    assert_eq!(code(m.run(&queue(&m, &p, &[0, 1], 10))), "nonce-spent");
    assert_eq!(code(m.run(&exq(&p, 109))), "too-early");
    assert_eq!(code(m.run(&exq(&p, 110))), "ok");
    assert_eq!(code(m.run(&exq(&p, 111))), "not-queued");
    // without a time lock, queuing is refused
    let mut m = create(2, 1, |_, _| {});
    let p = m.proposal(0, pay(1));
    assert_eq!(code(m.run(&queue(&m, &p, &[0], 10))), "no-timelock");
}

#[test]
fn expiry() {
    let mut m = create(2, 1, |c, _| c.timelock_ms = 100);
    let mut p = m.proposal(0, pay(1));
    p.expires_ms = 150;
    // the ETA (60 + 100) would fall after expiry
    assert_eq!(code(m.run(&queue(&m, &p, &[0], 60))), "expired");
    assert_eq!(code(m.run(&queue(&m, &p, &[0], 40))), "ok");
    assert_eq!(code(m.run(&exq(&p, 150))), "expired");
    assert_eq!(code(m.run(&exq(&p, 149))), "ok");
    // and the plan's windows
    let w = claims(&exq(&p, 149)).unwrap().window;
    assert_eq!((w.from, w.to), (Some(149), Some(150)));
    let w = claims(&queue(&m, &p, &[0], 40)).unwrap().window;
    assert_eq!((w.from, w.to), (None, Some(41)));
    assert!(claims(&exq(&p, 150)).is_err(), "an empty window is refused before planning");
}

#[test]
fn cancel_is_immediate_and_unqueues() {
    let mut m = create(3, 2, |c, _| c.timelock_ms = 100);
    let p = m.proposal(0, pay(1));
    m.run(&queue(&m, &p, &[0, 1], 10)).unwrap();
    let c = m.proposal(1, Action::Cancel(vec![0, 7]));
    assert_eq!(code(m.run(&queue(&m, &c, &[0, 1], 10))), "cancel-not-queued");
    assert_eq!(code(m.execute(&c, &[0])), "below-threshold");
    assert_eq!(code(m.execute(&c, &[0, 1])), "ok");
    assert!(m.st.queue.is_empty());
    assert_eq!(code(m.run(&exq(&p, 200))), "not-queued");
    // nonce 7 is spent too, so a proposal waiting in the room under it can never run
    assert_eq!(code(m.run(&queue(&m, &m.proposal(7, pay(1)), &[0, 1], 10))), "nonce-spent");
}

#[test]
fn queue_is_bounded() {
    let mut m = create(2, 1, |c, _| c.timelock_ms = 10);
    for n in 0..MAX_QUEUE as u64 {
        m.run(&queue(&m, &m.proposal(n, pay(1)), &[0], 1)).unwrap();
    }
    assert_eq!(code(m.run(&queue(&m, &m.proposal(99, pay(1)), &[0], 1))), "queue-full");
}

// ── R.2: a configuration change invalidates approvals gathered before it ──────

fn add(s: &Signer) -> Action {
    Action::Config(vec![ConfigChange::AddMember(mem(s, role::ALL, 1))])
}

#[test]
fn r2_approvals_before_a_change_stop_counting() {
    let mut m = create(3, 2, |_, _| {});
    let pay_p = m.proposal(0, pay(1)); // approved under epoch 0, not executed yet
    let a = m.approvals(&pay_p, &[0, 1]);
    let newbie = Signer::random();
    m.execute(&m.proposal(1, add(&newbie)), &[0, 1]).unwrap();
    assert_eq!(m.st.epoch, 1);
    let stale = Instruction::Execute { proposal: pay_p, approvals: a, executor: None };
    let e = apply(Some(&m.st), &stale, &CTX, None).unwrap_err();
    assert_eq!(e.code(), "stale-epoch");
    assert!(e.to_string().contains("epoch 0"), "{e}");
    // re-signed under the new epoch, it lands
    assert_eq!(code(m.execute(&m.proposal(0, pay(1)), &[0, 1])), "ok");
}

#[test]
fn r2_the_cutoff_is_the_queue() {
    let mut m = create(3, 2, |c, _| c.timelock_ms = 100);
    let p = m.proposal(0, pay(1));
    m.run(&queue(&m, &p, &[0, 1], 10)).unwrap();
    // remove member 1 (one of the two who approved), itself through the queue
    let k1 = m.s[1].key();
    let rm = m.proposal(1, Action::Config(vec![ConfigChange::RemoveMember(k1)]));
    m.run(&queue(&m, &rm, &[0, 2], 10)).unwrap();
    m.run(&exq(&rm, 110)).unwrap();
    assert_eq!(m.st.epoch, 1);
    assert!(rules::member(&m.st.config, &k1).is_none());
    // the payment queued before the change is still executable: the cutoff is the queue
    assert_eq!(code(m.run(&exq(&p, 110))), "ok");
}

#[test]
fn r2_a_removal_with_a_cancel_stops_the_queued_action() {
    let mut m = create(3, 2, |c, _| c.timelock_ms = 100);
    let p = m.proposal(0, pay(1));
    m.run(&queue(&m, &p, &[0, 1], 10)).unwrap();
    let cancel = m.proposal(1, Action::Cancel(vec![0]));
    m.execute(&cancel, &[0, 2]).unwrap();
    assert_eq!(code(m.run(&exq(&p, 110))), "not-queued");
}

#[test]
fn config_change_refused_whole_when_invalid() {
    let mut m = create(2, 2, |c, s| {
        c.limits.push(SpendingLimit { id: 1, signers: vec![s[1].key()], threshold: 1, amount: 10, period_ms: 100 })
    });
    let k1 = m.s[1].key();
    // removing member 1 would leave threshold 2 > weight 1, and member 1 signs for limit 1
    let rm = m.proposal(0, Action::Config(vec![ConfigChange::RemoveMember(k1)]));
    assert_eq!(code(m.execute(&rm, &[0, 1])), "member-in-limit");
    let rm = m.proposal(0, Action::Config(vec![ConfigChange::RemoveLimit(1), ConfigChange::RemoveMember(k1)]));
    assert_eq!(code(m.execute(&rm, &[0, 1])), "invalid-config");
    assert_eq!(m.st.epoch, 0, "a refused change changes nothing");
    let rm = m.proposal(0, Action::Config(vec![
        ConfigChange::RemoveLimit(1), ConfigChange::RemoveMember(k1), ConfigChange::SetThreshold(1),
    ]));
    assert_eq!(code(m.execute(&rm, &[0, 1])), "ok");
    assert_eq!(m.st.config.members.len(), 1);
}

// ── spending limits ────────────────────────────────────────────────────────────

fn limited() -> M {
    create(3, 3, |c, s| {
        c.timelock_ms = 1000;
        c.limits.push(SpendingLimit { id: 7, signers: vec![s[1].key(), s[2].key()], threshold: 1, amount: 100, period_ms: 1000 })
    })
}

fn spend(m: &M, nonce: u64, amount: u128, signers: &[usize], period: u64) -> Instruction {
    let sp = Spend { multisig: A, zone: ZONE, epoch: m.st.epoch, limit: 7, nonce, to: TO, amount, expires_ms: 1_000_000 };
    Instruction::Spend { approvals: signers.iter().map(|&i| m.s[i].spend(&sp)).collect(), spend: sp, period, period_ms: 1000 }
}

#[test]
fn spending_limit_skips_quorum_and_lock_up_to_its_amount() {
    let mut m = limited();
    assert_eq!(code(m.run(&spend(&m, 0, 60, &[1], 3))), "ok");
    assert_eq!(code(m.run(&spend(&m, 1, 41, &[2], 3))), "over-limit");
    assert_eq!(code(m.run(&spend(&m, 1, 40, &[2], 3))), "ok");
    // a new period resets the counter; an older one is refused
    assert_eq!(code(m.run(&spend(&m, 2, 100, &[1], 4))), "ok");
    assert_eq!(code(m.run(&spend(&m, 3, 1, &[1], 3))), "stale-period");
    // not a signer of this limit (member 0 is a member, but not the limit's)
    assert_eq!(code(m.run(&spend(&m, 3, 1, &[0], 5))), "not-a-limit-signer");
    // below the limit's own threshold
    assert_eq!(code(m.run(&spend(&m, 3, 1, &[], 5))), "below-threshold");
    // the period the limit has, not one the spender chose
    let mut bad = spend(&m, 3, 1, &[1], 5);
    if let Instruction::Spend { period_ms, .. } = &mut bad { *period_ms = 10 }
    assert_eq!(code(m.run(&bad)), "wrong-period");
    // the plan's window is the period
    let w = claims(&spend(&m, 3, 1, &[1], 5)).unwrap().window;
    assert_eq!((w.from, w.to), (Some(5000), Some(6000)));
}

#[test]
fn spend_signatures_are_not_proposal_approvals() {
    let mut m = limited();
    let sp = Spend { multisig: A, zone: ZONE, epoch: 0, limit: 7, nonce: 0, to: TO, amount: 1, expires_ms: 9_000_000 };
    let forged = m.s[1].approve(&m.proposal(0, pay(1)));
    let ins = Instruction::Spend { spend: sp, approvals: vec![Signed { key: m.s[1].key(), sig: forged.sig }], period: 0, period_ms: 1000 };
    assert_eq!(code(m.run(&ins)), "bad-signature");
}

// ── properties ────────────────────────────────────────────────────────────────

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, .. ProptestConfig::default() })]

    /// Whatever subset of members signs, an action runs exactly when their APPROVE weight
    /// reaches the threshold (R.1), and never twice.
    #[test]
    fn runs_iff_weight_reaches_threshold(weights in prop::collection::vec(1u16..4, 2..6), pick in prop::collection::vec(any::<bool>(), 6), k_frac in 0.1f64..1.0) {
        let n = weights.len();
        let total: u32 = weights.iter().map(|&w| w as u32).sum();
        let k = ((total as f64 * k_frac).ceil() as u32).clamp(1, total);
        let mut m = create(n, k, |c, _| for (i, w) in weights.iter().enumerate() { c.members[i].weight = *w });
        let mut who: Vec<usize> = (1..n).filter(|&i| pick[i]).collect();
        who.insert(0, 0); // the proposer always signs
        let weight: u32 = who.iter().map(|&i| weights[i] as u32).sum();
        let p = m.proposal(0, pay(1));
        let r = m.execute(&p, &who);
        prop_assert_eq!(r.is_ok(), weight >= k);
        if r.is_ok() {
            prop_assert_eq!(code(m.execute(&p, &who)), "nonce-spent");
        }
    }

    /// The nonce window: any order of distinct nonces lands once each, and the base never
    /// passes an unspent nonce.
    #[test]
    fn nonce_window_any_order(order in Just((0u64..40).collect::<Vec<_>>()).prop_shuffle()) {
        let mut m = create(1, 1, |_, _| {});
        for &n in &order {
            prop_assert!(m.execute(&m.proposal(n, pay(1)), &[0]).is_ok());
            prop_assert!(m.st.nonce_base <= 40);
        }
        prop_assert_eq!(m.st.nonce_base, 40);
        for &n in &order {
            prop_assert_eq!(code(m.execute(&m.proposal(n, pay(1)), &[0])), "nonce-spent");
        }
    }
}
