//! What a signature covers (docs/design/lez-msig.md §4): BIP-340 tagged hashes over borsh
//! bytes, one tag per purpose, so a signature for one purpose is worthless for another.

use crate::types::{Key, Proposal, Spend};
use sha2::{Digest, Sha256};

pub const TAG_PROPOSAL: &[u8] = b"muster-msig/v1/proposal";
pub const TAG_APPROVE: &[u8] = b"muster-msig/v1/approve";
pub const TAG_EXECUTE: &[u8] = b"muster-msig/v1/execute";
pub const TAG_SPEND: &[u8] = b"muster-msig/v1/spend";
pub const TAG_STATE_SEED: &[u8] = b"muster-msig/v1/state";

/// `SHA256(SHA256(tag) ‖ SHA256(tag) ‖ msg)` (BIP-340's tagged hash).
pub fn tagged(tag: &[u8], msg: &[u8]) -> Key {
    let t = Sha256::digest(tag);
    let mut h = Sha256::new();
    h.update(t);
    h.update(t);
    h.update(msg);
    h.finalize().into()
}

pub fn proposal_id(p: &Proposal) -> Key {
    tagged(TAG_PROPOSAL, &borsh::to_vec(p).expect("borsh"))
}

/// What an approver signs.
pub fn approve_msg(proposal_id: &Key) -> Key {
    tagged(TAG_APPROVE, proposal_id)
}

/// What an executor signs, when the multisig asks for one.
pub fn execute_msg(proposal_id: &Key) -> Key {
    tagged(TAG_EXECUTE, proposal_id)
}

/// What a limit's signer signs.
pub fn spend_msg(s: &Spend) -> Key {
    tagged(TAG_SPEND, &borsh::to_vec(s).expect("borsh"))
}

/// The multisig account's PDA seed: the adapter derives the account from it, and grants it to
/// an outflow.
pub fn state_seed(create_key: &Key) -> Key {
    tagged(TAG_STATE_SEED, create_key)
}
