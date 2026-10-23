//! Signing, for hosts and tests. A guest never signs (invariant 3): this module is compiled
//! only with the `signing` feature.

use crate::digest::{approve_msg, execute_msg, proposal_id, spend_msg};
use crate::types::{Key, Proposal, Signed, Spend};
use k256::schnorr::SigningKey;

/// A BIP-340 key: its secret and its x-only public key.
pub struct Signer(SigningKey);

impl Signer {
    pub fn from_secret(secret: &[u8; 32]) -> Self {
        Self(SigningKey::from_bytes(secret).expect("a valid secret key"))
    }
    pub fn random() -> Self {
        Self(SigningKey::random(&mut rand_core::OsRng))
    }
    pub fn key(&self) -> Key {
        self.0.verifying_key().to_bytes().into()
    }
    /// BIP-340 over a 32-byte message, with fresh auxiliary randomness.
    pub fn sign(&self, msg: &Key) -> Signed {
        let mut aux = [0u8; 32];
        rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut aux);
        self.sign_with_aux(msg, &aux)
    }
    /// BIP-340 with the given auxiliary randomness: deterministic, for test vectors.
    pub fn sign_with_aux(&self, msg: &Key, aux: &[u8; 32]) -> Signed {
        let sig = self.0.sign_raw(msg, aux).expect("BIP-340 signing");
        Signed { key: self.key(), sig: sig.to_bytes() }
    }
    pub fn approve(&self, p: &Proposal) -> Signed {
        self.sign(&approve_msg(&proposal_id(p)))
    }
    pub fn execute(&self, p: &Proposal) -> Signed {
        self.sign(&execute_msg(&proposal_id(p)))
    }
    pub fn spend(&self, s: &Spend) -> Signed {
        self.sign(&spend_msg(s))
    }
}
