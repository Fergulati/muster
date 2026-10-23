# programs/lez-msig/core/src/

`msig_core`: the multisig's rules (`docs/design/lez-msig.md` §3–§5).
- `types.rs`: what is stored and signed (borsh).
- `digest.rs`: the tagged hashes a signature covers.
- `rules.rs`: `claims` (from the instruction alone, for a plan) and `apply` (against the state).
- `error.rs`: every refusal, with a stable code.
- `sign.rs`: signing for hosts and tests (feature `signing`; a guest never signs).

`claims` and `apply` never panic. Signatures are checked last, so a cheap refusal costs no curve
arithmetic in the guest.
