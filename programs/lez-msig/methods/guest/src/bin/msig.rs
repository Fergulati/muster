//! lez-msig on LEZ v0.3: `run_program(plan, apply)` over msig_core (docs/design/lez-msig.md).
//!
//! plan, which sees no data:
//!   1. re-derives the multisig's account from (this program, the create key's seed, the
//!      placement) and refuses any other first row (§2: the counterfeit-state defence);
//!   2. takes the window and any outflow from the instruction alone (`msig_core::claims`);
//!   3. puts the instruction on the multisig's own shard, and routes the outflow as a chained
//!      call granted the multisig's own seed and nothing else, after checking the transaction's
//!      rows are exactly the ones that call selects.
//! apply runs every rule against the stored state (`msig_core::apply`). It runs before the
//! chained call, and a panic fails the whole transaction, so value leaves only when the members'
//! approvals hold.

use lee_core::{
    account::{AccountId, ProgramShardSelector},
    native_token::{custody_transfer, NATIVE_TOKEN_PROGRAM_ID},
    program::{run_program, AccountMeta, ChainedCall, Plan, PlanInput, TimestampValidityWindow},
};
use msig_core::{Ctx, Outflow, State};
use msig_v03::{key_of, multisig_account, seed, Effect, ProgramInstruction};

fn main() {
    run_program(plan, apply)
}

fn refuse(e: msig_core::MsigError) -> ! {
    panic!("{e}")
}

fn row(r: &AccountMeta) -> (AccountId, AccountId) {
    (r.account_id, r.program_account_id)
}

fn plan(input: &PlanInput, ins: ProgramInstruction) -> Plan {
    let program = input.self_account_id;
    let a = multisig_account(&program, &ins.create_key, &ins.placement);
    let rows = &input.accounts;
    assert!(!rows.is_empty(), "wrong-account: the multisig's account is the first row");
    assert_eq!(
        row(&rows[0]),
        (a, program),
        "wrong-account: the first row is not this multisig's account at its placement"
    );
    let claims = msig_core::claims(&ins.op).unwrap_or_else(|e| refuse(e));

    let mut plan = Plan::new(input);
    plan.effect(
        &rows[0],
        &Effect { multisig: key_of(&a), create_key: ins.create_key, program: key_of(&program), op: ins.op },
    );
    let w = TimestampValidityWindow::try_from((claims.window.from, claims.window.to))
        .unwrap_or_else(|_| panic!("expired: the instruction's window is empty"));
    plan.timestamp_window(w);

    let rest: Vec<(AccountId, AccountId)> = rows[1..].iter().map(row).collect();
    match claims.outflow {
        None => assert!(rest.is_empty(), "wrong-rows: this instruction takes only the multisig's account"),
        Some(Outflow::Pay { to, amount }) => {
            let to = AccountId::new(to);
            assert_eq!(
                rest,
                vec![(a, NATIVE_TOKEN_PROGRAM_ID), (to, NATIVE_TOKEN_PROGRAM_ID)],
                "wrong-rows: a transfer takes the vault and the recipient's balances"
            );
            plan.call(custody_transfer(a, seed(&ins.create_key), to, amount));
        }
        Some(Outflow::Invoke { program: target, rows: call_rows, data }) => {
            let selectors: Vec<ProgramShardSelector> = call_rows
                .iter()
                .map(|r| ProgramShardSelector::new(AccountId::new(r.account), AccountId::new(r.program)))
                .collect();
            let want: Vec<(AccountId, AccountId)> =
                selectors.iter().map(|s| (s.account_id, s.program_account_id)).collect();
            assert_eq!(rest, want, "wrong-rows: the transaction's rows are not the call's");
            plan.call(ChainedCall {
                program_account_id: AccountId::new(target),
                shard_selectors: selectors,
                instruction_data: data,
                pda_seeds: vec![seed(&ins.create_key)],
            });
        }
    }
    plan
}

fn apply(e: Effect, pre: &[u8]) -> Option<Vec<u8>> {
    let pre_state = if pre.is_empty() {
        None
    } else {
        Some(borsh::from_slice::<State>(pre).unwrap_or_else(|_| refuse(msig_core::MsigError::Decode)))
    };
    let ctx = Ctx { multisig: e.multisig, create_key: e.create_key };
    let post = msig_core::apply(pre_state.as_ref(), &e.op, &ctx, Some(&e.program)).unwrap_or_else(|err| refuse(err));
    Some(borsh::to_vec(&post).expect("borsh"))
}
