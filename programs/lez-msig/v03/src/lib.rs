//! The lez-msig program on LEZ v0.3 (docs/design/lez-msig.md §2): what the guest reads and
//! writes, shared with the host so both derive the same bytes and the same account.

use borsh::{BorshDeserialize, BorshSerialize};
use lee_core::{
    account::AccountId,
    encryption::ViewingPublicKey,
    program::PdaSeed,
    Identifier, NullifierPublicKey,
};
pub use msig_core;
use msig_core::{Instruction, Key};

/// Where the multisig's account lives. The plan re-derives the account from it and refuses
/// any other row, so a state written anywhere else is never granted the seed (§2, D10).
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Placement {
    /// A public PDA: the public posture.
    Public,
    /// A group-owned private PDA: the private posture. Its keys come from the members' group
    /// secret; inside a privacy-preserving transaction this stays in the proof.
    Private { npk: NullifierPublicKey, vpk: ViewingPublicKey, identifier: Identifier },
}

/// The program's instruction: which multisig, where it lives, and the core instruction.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct ProgramInstruction {
    pub create_key: Key,
    pub placement: Placement,
    pub op: Instruction,
}

/// The effect the plan puts on the multisig's own shard: the core instruction, and the
/// account and create key the plan verified, which `apply` cannot see for itself.
#[derive(Clone, Debug, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Effect {
    pub multisig: Key,
    pub create_key: Key,
    pub program: Key,
    pub op: Instruction,
}

/// The multisig account's PDA seed.
pub fn seed(create_key: &Key) -> PdaSeed {
    PdaSeed::new(msig_core::state_seed(create_key))
}

/// The multisig's account: the PDA of (program, seed) at its placement.
pub fn multisig_account(program: &AccountId, create_key: &Key, placement: &Placement) -> AccountId {
    let s = seed(create_key);
    match placement {
        Placement::Public => AccountId::for_public_pda(program, &s),
        Placement::Private { npk, vpk, identifier } => {
            AccountId::for_private_pda(program, &s, npk, vpk, *identifier)
        }
    }
}

pub fn key_of(a: &AccountId) -> Key {
    let mut k = [0u8; 32];
    k.copy_from_slice(a.as_ref());
    k
}
