//! lez_msig_module through its own trait, with no host: health and derive at once, and (when
//! MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM name a zone) a private Create as a job. exec answers with a
//! job id at once, a second exec meanwhile is "busy", and the job ends with the new note.
//!
//!   MSIG_LIVE_RPC=http://127.0.0.1:3040 MSIG_LIVE_PROGRAM=<hex> RISC0_DEV_MODE=1 \
//!     cargo test -p lez_msig_module -- --nocapture

use lez_msig_module::{LezMsigModule, LezMsigModuleImpl};
use msig_core::sign::Signer;
use msig_core::*;
use serde_json::{json, Value};

fn j(s: String) -> Value {
    serde_json::from_str(&s).unwrap()
}

#[test]
fn health_derive_and_a_private_create_as_a_job() {
    let mut m = LezMsigModuleImpl::default();
    let h = j(m.health());
    assert_eq!(h["ok"], true);
    assert_eq!(h["programImageId"].as_str().unwrap(), msig_host::image_id_hex());

    let program = std::env::var("MSIG_LIVE_PROGRAM").unwrap_or_else(|_| "11".repeat(32));
    let gms = hex::encode(rand::random::<[u8; 32]>());
    let ck = hex::encode(rand::random::<[u8; 32]>());
    let d = j(m.derive(json!({"program": program, "gms": gms, "createKey": ck}).to_string()));
    assert_eq!(d["account"].as_str().unwrap().len(), 64, "{d}");
    assert_eq!(j(m.derive("nope".into()))["error"], "bad-request");
    assert_eq!(j(m.exec(json!({"program": program}).to_string()))["error"], "bad-request");
    assert_eq!(j(m.fund(json!({}).to_string()))["error"], "bad-request");
    assert_eq!(j(m.send(json!({"rpc": "http://127.0.0.1:1", "message": "00", "proof": "00", "witnesses": []}).to_string()))["error"],
               "failed", "an unreadable message is refused before anything is sent");

    let Ok(rpc) = std::env::var("MSIG_LIVE_RPC") else {
        eprintln!("live part skipped: set MSIG_LIVE_RPC and MSIG_LIVE_PROGRAM");
        return;
    };
    let s: Vec<Signer> = (0..2).map(|_| Signer::random()).collect();
    let config = Config {
        members: s.iter().map(|x| Member { key: x.key(), roles: role::ALL, weight: 1 }).collect(),
        threshold: 2, timelock_ms: 0, open_execution: true, actions: action_kind::ALL, targets: vec![], limits: vec![],
    };
    let op = Instruction::Create { zone: [0x2e; 32], config };
    let req = json!({"rpc": rpc, "program": program, "gms": gms, "createKey": ck, "pre": null,
                     "op": hex::encode(borsh::to_vec(&op).unwrap())});
    let started = std::time::Instant::now();
    let r = j(m.exec(req.to_string()));
    let id = r["job"].as_str().expect("a job id at once").to_string();
    assert!(started.elapsed().as_secs() < 2, "exec answers at once");
    assert_eq!(j(m.exec(req.to_string()))["error"], "busy", "one proof at a time");
    let done = loop {
        let v = j(m.job(id.clone()));
        if v["state"] != "proving" { break v; }
        std::thread::sleep(std::time::Duration::from_millis(500));
    };
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(done["account"], d["account"], "the note is the derived account's");
    assert!(done["post"].as_str().unwrap().len() > 64 && done["hash"].as_str().unwrap().len() == 64);
    assert_eq!(j(m.job("ab".repeat(16)))["error"], "unknown-job");
    assert_eq!(j(m.forget(id.clone()))["ok"], true);
    assert_eq!(j(m.job(id))["error"], "unknown-job", "forgotten, the note with it");
    eprintln!("a private Create as a job: {:?}", started.elapsed());
}
