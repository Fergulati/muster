//! Ground truth for any other implementation of lez-msig's bytes (muster's Nim port,
//! module/src/lez/msig.nim): every encoding, hash and derivation the program and its signers
//! depend on, from fixed inputs.
//!
//!   cargo run -p msig_host --bin msig_vectors > module/tests/vectors/lez-msig/vectors.json

use lee_core::account::AccountId;
use msig_core::sign::Signer;
use msig_core::*;
use msig_host::{Msig, ProgramInstruction};

fn hx(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn entry(name: &str, value: &[u8]) -> String {
    format!("    \"{name}\": \"{}\"", hx(value))
}

fn main() {
    let program = AccountId::new([0x11; 32]);
    let create_key: Key = [0x22; 32];
    let zone: Key = [0x2e; 32];
    let s1 = Signer::from_secret(&[0x01; 32]);
    let s2 = Signer::from_secret(&[0x02; 32]);
    let s3 = Signer::from_secret(&[0x03; 32]);
    let m = Msig::public(program, [0; 8], create_key);
    let a = m.key();

    let member = |s: &Signer, roles: u8, weight: u16| Member { key: s.key(), roles, weight };
    let config = Config {
        members: vec![member(&s1, role::ALL, 1), member(&s2, role::PROPOSE | role::APPROVE, 2), member(&s3, role::EXECUTE, 1)],
        threshold: 2,
        timelock_ms: 3_600_000,
        open_execution: false,
        actions: action_kind::ALL,
        targets: vec![[0x55; 32]],
        limits: vec![SpendingLimit { id: 7, signers: vec![s1.key(), s2.key()], threshold: 1, amount: 1_000_000, period_ms: 86_400_000 }],
    };
    let actions = vec![
        ("transfer", Action::Transfer { to: [0x0e; 32], amount: 400 }),
        ("call", Action::Call { program: [0x55; 32], rows: vec![Row { account: a, program: [0x55; 32] }, Row { account: [0x0e; 32], program: [0x55; 32] }], data: vec![1, 2, 3] }),
        ("config", Action::Config(vec![
            ConfigChange::AddMember(member(&Signer::from_secret(&[0x04; 32]), role::APPROVE, 1)),
            ConfigChange::RemoveMember(s3.key()),
            ConfigChange::SetRoles { key: s1.key(), roles: role::PROPOSE },
            ConfigChange::SetWeight { key: s2.key(), weight: 3 },
            ConfigChange::SetThreshold(3),
            ConfigChange::SetTimelock(0),
            ConfigChange::SetOpenExecution(true),
            ConfigChange::SetActions(action_kind::TRANSFER),
            ConfigChange::SetTargets(vec![]),
            ConfigChange::AddLimit(SpendingLimit { id: 8, signers: vec![s2.key()], threshold: 1, amount: 5, period_ms: 60_000 }),
            ConfigChange::RemoveLimit(7),
        ])),
        ("cancel", Action::Cancel(vec![3, 300])),
    ];
    let aux = [0x5a; 32];
    let mut out = vec![
        entry("program", program.as_ref()),
        entry("create_key", &create_key),
        entry("zone", &zone),
        entry("state_seed", &state_seed(&create_key)),
        entry("multisig_public", &a),
        entry("key1", &s1.key()),
        entry("key2", &s2.key()),
        entry("key3", &s3.key()),
        entry("config", &borsh::to_vec(&config).unwrap()),
        entry("create_envelope", &borsh::to_vec(&ProgramInstruction {
            create_key,
            placement: msig_v03::Placement::Public,
            op: Instruction::Create { zone, config: config.clone() },
        }).unwrap()),
    ];
    for (name, action) in actions {
        let p = Proposal { multisig: a, zone, epoch: 5, nonce: 9, action, expires_ms: 1_800_000_000_000, proposer: s1.key() };
        let id = proposal_id(&p);
        let ap1 = s1.sign_with_aux(&approve_msg(&id), &aux);
        let ap2 = s2.sign_with_aux(&approve_msg(&id), &aux);
        let ex = s3.sign_with_aux(&execute_msg(&id), &aux);
        out.push(entry(&format!("{name}.proposal"), &borsh::to_vec(&p).unwrap()));
        out.push(entry(&format!("{name}.proposal_id"), &id));
        out.push(entry(&format!("{name}.approve_msg"), &approve_msg(&id)));
        out.push(entry(&format!("{name}.execute_msg"), &execute_msg(&id)));
        out.push(entry(&format!("{name}.approve_sig1"), &ap1.sig));
        out.push(entry(&format!("{name}.execute_sig3"), &ex.sig));
        let exec = Instruction::Execute { proposal: p.clone(), approvals: vec![ap1.clone(), ap2.clone()], executor: Some(ex.clone()) };
        out.push(entry(&format!("{name}.execute_envelope"), &borsh::to_vec(&m.envelope(exec)).unwrap()));
        let queue = Instruction::Queue { proposal: p.clone(), approvals: vec![ap1, ap2], executor: Some(ex.clone()), at_ms: 1_700_000_000_000 };
        out.push(entry(&format!("{name}.queue_envelope"), &borsh::to_vec(&m.envelope(queue)).unwrap()));
        let exq = Instruction::ExecuteQueued { proposal: p, executor: Some(ex), at_ms: 1_700_003_600_000 };
        out.push(entry(&format!("{name}.execute_queued_envelope"), &borsh::to_vec(&m.envelope(exq)).unwrap()));
    }
    let sp = Spend { multisig: a, zone, epoch: 5, limit: 7, nonce: 10, to: [0x0e; 32], amount: 999, expires_ms: 1_800_000_000_000 };
    let sp_sig = s1.sign_with_aux(&spend_msg(&sp), &aux);
    out.push(entry("spend", &borsh::to_vec(&sp).unwrap()));
    out.push(entry("spend_msg", &spend_msg(&sp)));
    out.push(entry("spend_sig1", &sp_sig.sig));
    out.push(entry("spend_envelope", &borsh::to_vec(&m.envelope(Instruction::Spend {
        spend: sp,
        approvals: vec![sp_sig],
        period: 19_675,
        period_ms: 86_400_000,
    })).unwrap()));
    let state = State {
        version: VERSION,
        zone,
        create_key,
        epoch: 5,
        config,
        usage: vec![LimitUsage { id: 7, period: 19_675, used: 999 }],
        nonce_base: 9,
        consumed: { let mut c = [0u8; 32]; c[0] = 0b0000_0110; c },
        queue: vec![Queued { nonce: 12, proposal_id: [0x77; 32], eta_ms: 1_700_003_600_000, expires_ms: 1_800_000_000_000 }],
    };
    out.push(entry("state", &borsh::to_vec(&state).unwrap()));
    // a private note as a member decrypts it: the program's shard (the state) and the vault
    let note = lee_core::account::Account { nonce: lee_core::account::Nonce(0x0102_0304), ..Default::default() }
        .with_shard(program, borsh::to_vec(&state).unwrap().try_into().unwrap())
        .with_shard(lee_core::native_token::NATIVE_TOKEN_PROGRAM_ID, lee_core::native_token::encode_balance(3_800));
    out.push(entry("note", &borsh::to_vec(&note).unwrap()));
    out.push(format!("    \"aux\": \"{}\"", hx(&aux)));
    println!("{{\n  \"source\": \"programs/lez-msig/host/src/bin/msig_vectors.rs\",\n  \"vectors\": {{\n{}\n  }}\n}}", out.join(",\n"));
}
