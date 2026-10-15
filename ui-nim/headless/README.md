# muster-headless-host — logos-core and muster_module, driven from stdin

A small host that starts logos-core in its own process, loads `muster_module` with its dependencies, and calls any loaded module from a line on stdin. It needs no display, no view and no daemon. It is how muster is driven headless, whatever the state of the Logos host stack. It is the Nim port (exo-607 T7, ADR-019) of the C++ host that lived in `module/tools/headless-host/`.

## Run it

```
cd ui-nim && nix build .#headless-host
python3 ui-nim/headless/drive.py result/bin/muster-headless-host <modules-dir> <logos_host> <data-dir> <instance>
health   -> OK	ok
identity -> OK	{"address":"0x97db…","ed25519":"0dca…","x25519":"7c8e…","btcPubKey":"03ca…"}
describe -> OK	{"available":true,"defaultChainId":"31337","chainId":31337,"safe":"0xEb45…
```

These are real module results. `scripts/nim-headless-probe.sh` does the same against the modules the C++ runner was built with, and checks the answers. The modules dir is any runner's (`make build`); `<logos_host>` is the runner's too, which the build's wrapper already sets as `LOGOS_HOST_PATH`.

## Protocol

- **stdin:** one call per line, tab-separated: `<module>\t<method>\t<arg1>\t<arg2>…`. Arguments go as strings. `quit`, `exit` or the end of input stops it.
- **Replies:** `OK\t<result>` or `ERR\t<why>`, one line each, printed when each reply arrives. Replies go on stdout, or on `--reply-file <path>`, away from the modules' own logs, which also write to stdout.
- **Flags:**
  - `--modules-dir <dir>` and `--persistence <dir>`, both required;
  - `--instance <id>` sets `LOGOS_INSTANCE_ID`, so two hosts use distinct sockets, the two-instance handle;
  - `--load <module>`, `muster_module` by default.

`drive.py` is the reference driver: it spawns the host, sends calls and reads the replies.

## How it works

It starts the core exactly as the Nim app does, with `startCore` in `ui-nim/app/logos_core.nim`:
1. the modules dir and the persistence base;
2. `capability_module`;
3. the module to drive, with its dependencies;
4. a token registered with `capability_module` for this host as `muster_headless`.

Every call is an `lp_*` client call from the SDK's `PluginProxy`, made asynchronously (`callAsyncThen`). So the Qt event loop keeps running between calls, and delivery's transport pumps, which a two-instance run needs. stdin is read on the same loop (a `QSocketNotifier`).

The C++ host took six workarounds to get there: the capability gate off, `logos_core_init`, raw `QRemoteObjectNode` replicas acquired at startup, a token from `logos_core_get_token`, and a pending-call watcher instead of a nested wait. None of them is needed over `lp_*`. `docs/labbook/logoscore-out-of-process-module-auth.md` tells that story.
