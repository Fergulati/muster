# ui-nim/headless — the headless host (exo-607 T7)

`muster_headless_host.nim` starts logos-core in-process, loads a module (muster_module by default) with its dependencies, and turns each stdin line into an lp_* call. The protocol and how to run it are in `README.md`; `drive.py` is the reference driver, and `scripts/nim-headless-probe.sh` its check.

- **The core start is the app's** (`../app/logos_core.nim`, `startCore`). Change it there, for both.
- **Calls are async** (`PluginProxy.callAsyncThen`): the event loop must keep running between calls, or delivery stops pumping.
- **Replies are one line each.** A newline in a result is escaped as `\n`, so a reader can split on lines.
