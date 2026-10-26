# programs/lez-msig/methods/guest/src/bin/

`msig.rs`: the program on LEZ v0.3, a thin `run_program(plan, apply)` adapter over `msig_core`.
The plan checks the multisig's account and the transaction's rows, and routes outflows. `apply`
runs the core's rules. Keep it thin: a rule added here would not reach the actor adapter.
