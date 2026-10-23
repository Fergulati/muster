# programs/lez-msig/host/tests/

`v03_state.rs`: the program on LEE's own `V03State`, with no sequencer. It covers the public posture
end to end, the plan's account and row checks, windows, R.2, a spending limit, and the private posture
with dev-mode receipts. Refusals are matched by their `MsigError` code.
