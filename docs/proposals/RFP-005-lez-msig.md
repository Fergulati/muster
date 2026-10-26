<!-- DRAFT for the logos-co/rfp proposal form (RFP-005). Each "##" section is one form field.
     [brackets] are the operator's to fill: team, contact, budget, audit quote. Everything else is
     grounded in code on corpetty/muster (PR #344) and cites it. -->

# RFP-005 proposal: lez-msig, a private-by-default multisig with an encrypted room

## RFP ID
RFP-005 — Multisig and Coordination

## Your Project Name
lez-msig, run from a Muster room

## Team or Organization Name
[team]

## Primary Contact
[contact]

## Team Members
[names, roles, links]

## Project Summary

A multisig has two halves: the program that enforces M-of-N, and the place where members agree on
what to sign. Every bid so far spends most of its words on the first. Every production multisig
leaks through the second: Safe through a relay that sees everything, Squads through public on-chain
votes, Bitcoin through whatever chat the signers happen to use. The Bybit and WazirX losses
happened in that second half, where what signers were shown differed from what they signed.

We are not proposing a design. We are proposing to finish one that already runs:

- **The program is written and running** (`programs/lez-msig/`).
  - The same program runs a multisig over a public PDA or over a group-owned private PDA.
  - Members' approvals are collected off-chain and verified inside the program at execution.
  - On a live LEZ v0.3.0 sequencer, three privacy-preserving transactions were each accepted:
    a private multisig was created, funded and paid out 2-of-3. Nothing public exists at the
    multisig's id (`host/tests/live_private.rs`).
- **The coordination layer is shipping software.** Muster is a released Logos client
  (muster-v0.3.2, in Basecamp through its own catalogue). A Muster room is an encrypted, signed,
  epoch-keyed log, and it re-keys forward when membership changes.
  - The multisig is created from a room: a ceremony binds each member's approval key to their room
    identity.
  - It is proposed, approved and executed from that room. This runs end to end against the
    deployed program (`module/tests/lez_msig_live_e2e.nim`), and through two real Muster
    clients on screen (`scripts/lez-msig-self-test.sh`). The card decodes the exact bytes each
    approval signs.
  - The private posture runs from the room too. The prover is a Rust Logos module,
    `lez_msig_module`, and it holds no key. The opener seals the group secret to each member,
    and each new note is sealed into the room once the chain includes its transaction.
    Create, a deposit signed in the member's own keystore, and a 2-of-3 payment have run from
    a room (`module/tests/lez_msig_private_e2e.nim`, dev-mode proving). The chain's copy of
    the payment names no member key and no approval.
- **The hardest unpriced item is priced.** RFP §Risks names approval-verification cost.
  - With real proving on a 64-core CPU, a private payment carrying M approvals proves in 150.7 s
    at M=1, 208.5 s at M=5 and 288.1 s at M=10: about 15 s per approval.
  - The transaction is a constant 228 KB, independent of M.
  - P.2's M ≥ 5 is comfortably met (`programs/lez-msig/BENCHMARKS.md`).

What remains is the work that turns a working core into an audited product: hardening the Logos
module and the mini-app, the 0.4 port, the documentation, and an audit.

## Technical Approach

**Architecture.** One program and one account per multisig. The rules live in a core crate with
no LEZ dependency (`msig_core`), and thin adapters map them onto a runtime: v0.3's
`run_program(plan, apply)` today, and `dev`'s transactional actors (LEZ PR #935, which we expect
testnet 0.4 to run) in this grant. Posture is placement, not a fork: the same audited program runs
over a public PDA (the public posture) or a group-owned private PDA (the default).

**Approvals (F.1, F.2, R.1).**
- Each member holds a per-multisig BIP-340 approval key, derived in their own keystore and never
  exported.
- Proposals and approvals are collected in the room (F.2: off-chain). One transaction carries the
  proposal and its approvals.
- The program verifies, at execution, distinct current members holding the APPROVE role,
  weighted, over exactly this proposal; the proposer's own signature is required.
- The signed digest is a BIP-340 tagged hash committing to the zone, the multisig's account, the
  configuration epoch, a nonce, the action and an expiry. A signature is worthless anywhere else.
- Replay: a 256-nonce window. Nonces can be used in any order and only once, the state stays
  bounded, and a private transaction carries no extra marker accounts.
- Cost: RISC Zero's accelerated k256, patched into our guest only, verifies a BIP-340 signature
  2.9× faster than stock.

**Configuration and R.2 (F.5).**
- A configuration change is a proposal through the same quorum and time lock.
- Executing one bumps the epoch, so every approval gathered under the old configuration stops
  counting at once.
- The cutoff is the queue. An action already queued survives a change; the current quorum can
  cancel it immediately, because cancels are never time-locked.
- A removed member's queued action can therefore be cancelled before its ETA. The mini-app offers
  that cancel with every removal.

**Roles (F.6).**

| Role | What the program guarantees |
|---|---|
| PROPOSE | The program refuses an action its proposer did not sign. A proposing key need not be an approving key. |
| APPROVE | Only APPROVE signatures count toward the threshold, by weight. |
| EXECUTE | With open execution off, an EXECUTE member must sign the execution. In the private posture, executing also requires the group keys. |

**Time lock, expiry, spending limits (F.7, F.8).**
- A program reads no clock, so every time is a claim the plan binds with a sequencer-enforced
  validity window.
- A Queue lands no later than its claimed time, so the ETA is pessimistic and never early.
  ExecuteQueued lands no earlier than the ETA, and expiry bounds both.
- Spending limits let k of a limit's own signers spend up to an amount per period, the period bound
  the same way. Limits are the one bypass of the quorum, and the profile declares them as such.

**Arbitrary calls (F.3).**
- A `Call` action chains any program, granted exactly the multisig's own PDA seed.
- The plan re-derives the multisig's account from its placement and refuses any other row. So a
  counterfeit state written elsewhere is never granted the seed: one quorum cannot move another
  multisig's vault.
- The published lez-multisig passes seeds unchecked, which is that bug (reported in our tracker as
  exo-325).

**Registry and decode-before-sign (F.4, U.6).**
- The room's effect is the proposal's exact borsh bytes, and the card decodes those bytes, so what
  a member sees is what their approval signs.
- Target programs are decoded through a registry of program descriptors keyed by the program's
  account and image id, shipped inside the signed Muster package and cross-checked against the
  chain's deployment header.
- An unregistered target shows the raw program id, rows and instruction bytes, with an explicit
  warning, and approving it takes a second confirmation.

**Private posture (F.10, Privacy).**
- The multisig's state and vault are two shards of one private PDA, whose keys come from a group
  master secret. The secret is sealed to each member's encryption identity inside the room.
- It lets a member operate the multisig, but not spend: the program is the only gate.
- An execution is one privacy-preserving transaction with no public signer: on chain, a nullifier,
  a commitment and padded notes. It is fee-exempt on v0.3; LEZ PR #949 would add a fee, see
  Risks.
- The program is deployed immutable, so its image claim can be Undisclosed.
- What each observer sees, item by item, is §7 of `docs/design/lez-msig.md`, written to U.5's
  standard. The correlations that remain (Privacy-3) are listed there:
  - the timing of room traffic against executions;
  - public validity-window bounds;
  - a public payee's credit;
  - the removed-member window.

**Selective disclosure.** Three tiers, with their limits stated:
- a narrow audience gets the PDA's viewing key: read-only on `dev`; on v0.3 it can also stall the
  multisig;
- a wide audience gets Muster's self-verifying signature-audit export of the room's record;
- ongoing assurance comes from re-disclosure, verified against the chain's commitment set.

**The coordination room (F.9, Coordination Architecture).**
- **Binding.** In the creation ceremony each member's approval key is bound to their room identity
  by two signatures, the approval key over (room, create key, identity) and the room identity over
  the event. The binding exists only inside the room.
- **Program verification.** The program verifies approvals against the approval keys in its own
  state.
- **Room attacks.** Withholding, reordering, replaying, injecting, or showing members different
  views cannot produce an invalid execution: the program re-verifies everything, replay spends a
  nonce, and a stale view yields approvals under a stale epoch, which the program refuses. What
  remains is liveness.
- **Reconciliation.** On every executed configuration change, the room re-keys forward to the
  program's member set (F-16).

**S.2, the chat module, stated plainly.**
- Today the room is Muster's, not chat_module's.
- chat_module 0.3.0 has no member removal, so the reconciliation above cannot be done on it. It
  also sends the room id in the clear, and registers key packages with a central HTTP service. No
  bid fixes these.
- Muster's room sits behind a `ConversationCrypto` seam built for a chat-module binding.
- Milestone 4 delivers that binding, and contributes member removal upstream if chat_module has
  not shipped it by then.

**Removal and the group secret.** A shared secret cannot be revoked. Until the remaining members
migrate (a new group secret, a new PDA, and an M-of-N transfer of the vault, offered with every
removal), a removed member can still read the state and can stall the multisig by consuming its
note. They can never spend. We document this rather than hide it.

**Anticipated challenges.**
- The 0.4 runtime: the actor model is still moving (clock, fees and system addresses all have open
  PRs).
- PR #949 would make private transactions pay a fee from an authorizing account, which links the
  executor.
- Proving time on consumer hardware. Our numbers are 64-core CPU figures; Milestone 1 adds a
  laptop-class benchmark and a GPU one.

## Milestones, Payout and Timeline

**Milestone 1: Testnet and measurement.** 3 weeks, [$].
- Deploy on the public LEZ testnet; both postures live there, with real proving.
- P.1/P.2 benchmarks on testnet: an 8-core laptop-class machine, the 64-core reference, and a GPU
  prover; the largest viable M; transaction sizes.
- The room-side reconciliation of membership on configuration change.
- Spending limits proposed from the room.

**Milestone 2: The Logos module, CLI and private posture end to end.** 6 weeks, [$].
- `lez_msig_module` (U.1) exists today as the prover: jobs, one proof at a time, no key held.
  This milestone completes it: create, propose, approve, reject, execute, and manage members and
  policies, with progress events while a proof runs.
- The CLI over `logoscore` (U.3), covering the full operator journey.
- The private posture from the room, with real proving:
  - The group secret sealed per member and the notes carried in the room run today in dev mode.
  - This milestone runs them with real proving, on the testnet.
  - It adds recovery of a note by scanning the chain with the group's viewing key.
- Migration on removal.
- The selective-disclosure tiers.

**Milestone 3: The mini-app, registry and documentation.** 6 weeks, [$].
- The QML mini-app (U.2): the proposal list beside the coordination room, the decode-before-sign
  card on the registry (F.4/U.6), queue and ETA, limits, and clear refusals (U.7).
- The program descriptor registry.
- Designs (S.11).
- Documentation:
  - the per-action public/private table (U.5);
  - the README (S.8);
  - API docs (S.9);
  - CLI docs (S.10).
- Published in Muster's own catalogue (S.12).

**Milestone 4: Testnet 0.4, the IDL and the chat-module binding.** 5 weeks, [$].
- The actor adapter over the same core; deployed and tested on testnet 0.4 (S.3/S.4).
- The IDL (U.4): through SPEL if it supports 0.4 by then; otherwise a generated IDL from the core
  types, with the SPEL port offered upstream.
- The chat-module binding behind `ConversationCrypto`, with upstream removal support (S.2).
- CI against a standalone sequencer, green on the default branch (S.5/S.6).

**Milestone 5: Audit.** 6–8 weeks, [$ including the audit].
- A tier-1 audit of the program, the approval-verification path, configuration changes and the
  time lock, and spending limits (S.13). Named firm: [OpenZeppelin / Trail of Bits / Spearbit /
  Cantina]; quote: [$].
- A fix round, then the published report.

## Total Requested Budget (USD)
[sum of the milestones]

## Relevant Experience

- Muster: https://github.com/corpetty/muster, released in Basecamp through its own catalogue.
- The work this proposal finishes, open for review: corpetty/muster PR #344.
  - The program: `programs/lez-msig/`, held by 24 core-rule tests and 8 state-machine tests, plus
    the live private test.
  - Muster's driver, ceremony and settlement, end to end against the deployed program.
  - The benchmark.
- The same repo already drives:
  - a Safe on Sepolia from two Basecamp profiles;
  - Bitcoin multisig through PSBT;
  - the LEZ vote-locus multisig, live on the LEZ testnet in 2026-09;
  - FROST on Bitcoin and LEZ;
  - bill splits across EVM, Bitcoin, LEZ private and Monero.

## Post-Delivery Plan

[who maintains it]

The program, the module and the mini-app live in the Muster repository and catalogue, and are
maintained with Muster. LEZ releases are tracked as they ship; the core/adapter split keeps a
runtime port to one thin adapter.

<!-- Operator notes, not for the form:
     - The other bids range $110k-$190k all-in, audits $25k-$50k. #221 (Gemot) and #222 (Accord)
       are the strong ones: both have real code and measurements on LEZ.
     - Rerun msig_bench on an idle machine before quoting figures; the 2026-10-23 run shared the
       host with builds.
     - The testnet deployment (Milestone 1) needs the testnet funder funded: infra/lez/funder.sh --zone testnet account. -->
