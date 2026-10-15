# Muster on every platform Basecamp ships on

**As of 2026-10-15 (exo-b89).** What it takes to build Muster for each platform Basecamp
0.3.2 is released for, and what is left for the ones not built yet. The code and the
workflow win over this page.

## How a package carries a platform

A `.lgx` is a container of native builds, one directory per platform under `variants/`, and
Basecamp installs the one matching its own platform. Both of Muster's packages are native:
`muster_module` is Nim compiled into a shared library, and `muster_ui` carries a compiled C++
Qt plugin beside its QML. So a package with no variant for a platform cannot be installed
there at all.

Basecamp 0.3.2 is released for four platforms, and the official catalogue builds for the
same four (`logos-co/logos-modules-release-action`, `release.yml@v1.9`):

| Platform | Basecamp 0.3.2 | Muster |
|---|---|---|
| `linux-amd64` | AppImage | built since the first release |
| `linux-arm64` | AppImage (aarch64) | **built** by `.github/workflows/lgx-variants.yml` on `ubuntu-24.04-arm` (exo-b89) |
| `darwin-arm64` | `.dmg` | not built; mapped below |
| `windows-x86_64` | `setup.exe` | not built; mapped below |

## How the variants are built and released

`.github/workflows/lgx-variants.yml` builds `.#lgx-portable` for each package natively on
each platform's GitHub runner. It checks that each build is tagged with the variant it is
for, then merges each package's variants into one `.lgx` with `lgx merge`. It runs on pull
requests that touch `module/` or `ui/`, on `v*` tags, and by hand. It publishes nothing: its
`lgx-merged` artifact holds `muster_module.lgx` and `muster_ui.lgx`.

`scripts/catalog-release.sh --from-run <run id>` takes those packages into a release. The
run must be that workflow, it must have succeeded, and it must have built exactly HEAD.
Each package's manifest must carry every Linux variant. The assets are named
`<package>-<version>.lgx`, as the official catalogue names its own. Without `--from-run`,
the script still builds `linux-amd64` locally, as before.

Adding a platform means: the flake builds it, a matrix row for it in the workflow, and the
platform added to `PLATFORMS` in the release script.

## What Muster depends on, per platform

Each dependency's newest version in the official catalogue index, 2026-10-15:

| Package | Muster needs it | linux-amd64 | linux-arm64 | darwin-arm64 | windows-x86_64 |
|---|---|---|---|---|---|
| delivery_module | required | ✓ | ✓ | ✓ | ✓ |
| lez_core | required (module and ui) | ✓ | ✓ | ✓ | **✗** |
| keystore_module, eth_rpc_module, tx_sender_module, fee_module | required | ✓ | ✓ | ✓ | ✓ |
| liblogos_lez_rln_module | required (ui) | ✓ | ✓ | ✓ | **✗** |
| liblogos_rln_module | required (ui) | ✓ | ✓ | ✓ | ✓ |
| verified_proxy_module | optional | ✓ | ✓ | ✓ | ✓ |
| libp2p_module | optional (via delivery) | ✓ | ✓ | ✓ | ✗ |
| monero_wallet_backend and its modules | optional | ✓ | ✓ | ✓ | ✓ |

linux-arm64 and darwin-arm64 have every dependency. Windows lacks two that Muster requires.

## darwin-arm64: what is left

Every dependency exists, and the builder supports macOS: it names libraries `.dylib`, sets
`install_name` to `@rpath`, and links Apple with `@loader_path`. The work:

1. **Bundle libsodium.** It is Muster's only external native library: secp256k1 and BearSSL
   are compiled from source inside their Nim packages, and nothing links OpenSSL. On Linux
   the fork's RUNPATH commit finds libsodium. On macOS the Apple branch never applies that
   suffix, so libsodium would resolve through its absolute `/nix/store` install name and
   fail outside nix. **Recommended: link libsodium statically (`.a`) on every platform.**
   That fixes macOS, removes the need for the Linux-only RUNPATH commit, and is what Windows
   needs anyway. The alternative is copying the `.dylib` in and rewriting its install name.
2. **A matrix row** `darwin-arm64` on `macos-latest`, with the official action's "Ensure
   Metal Toolchain" step.
3. **Check the fork's Nim link line on Apple.** It links the Nim static library plus
   `pthread` there, which looks right, but nothing has built it yet.
4. **The test harness is Linux-only.** `module/tests/run-suite.sh` and
   `tests/probes/config.nims` look for `libsodium.so` and pass `-Wl,-rpath`, and
   `probe_return_marshalling_host` searches `/nix/store` for `lib*.so`. A release does not
   need the suite to run on a Mac. Running it there would be the confidence check.
5. **Acceptance:** install the merged packages into Basecamp's `.dmg` on a Mac and run a room
   between it and a Linux instance, as R6 did (`docs/labbook/muster-in-basecamp-031.md`).

Estimate: small, once a Mac is available to accept it.

## windows-x86_64: what is left

Larger, and it rests on two things outside Muster's code.

1. **The builder.** Neither builder Muster pins has a Windows path:
   - `module/` pins the fork `corpetty/logos-module-builder@c10a94c`;
   - `ui/` pins `logos-co/logos-module-builder@4717b9a`.

   Upstream builders since then do: `lib/resolvePlatforms.nix`, and a mingw
   `packages.x86_64-windows` built from Linux, which is how the official catalogue builds
   Windows (`.#packages.x86_64-windows.lgx-portable`). The fork's three Nim commits
   (`nim.packages`, `nim c --app:staticlib`, the link line) would need to move onto it. That
   is R8 (`exo-d4d.8`: Muster leaves the forked builder), so **Windows waits on R8.**
2. **Nim cross-compiles to mingw.** The fork runs the native `nim c --app:staticlib`; Windows
   needs `--os:windows --cpu:amd64` with the mingw gcc. On the link line,
   `pthread dl m` becomes `ws2_32 bcrypt advapi32`, since chronos needs Winsock.
3. **libsodium for mingw:** a static `pkgsCross.mingwW64.libsodium` (see darwin step 1).
4. **Two required dependencies have no Windows build:** `lez_core` and
   `liblogos_lez_rln_module`. Either:
   - upstream builds them for Windows; or
   - Muster declares them optional there and hides what needs them (the LEZ wallet, the
     private split, LEZ multisig and FROST on LEZ). `modules_state` already shows how Muster
     runs without a module.

   This is a product decision, not a build fix.
5. **Code, small:**
   - `module/src/transport/delivery.nim:114` imports `stderr` from `<stdio.h>` as a variable.
     Under mingw it is a macro, so use Nim's own `stderr`.
   - `module/src/crypto/keystore.nim:278` sets the keyfile owner-only with
     `setFilePermissions`. On Windows that only toggles read-only, so the keyfile would be
     readable by other local users unless an ACL is set. This is a security gap; fix it
     before shipping Windows, not after.
   - The default data directory falls back to the temp directory when the host gives no
     persistence path (`muster_module.nim`, `MUSTER_DATA_DIR`). The hosts always give one,
     but the fallback is wrong everywhere.
6. **The ui plugin.** The C++ is portable Qt (no POSIX calls, no `Q_OS` branches), so it
   needs only the builder's Windows path from step 1.
7. **Acceptance:** Basecamp's `setup.exe` on Windows, with a room against a Linux instance.

Estimate: medium, after R8 and the LEZ decision.

## What stays Linux-only

Linux-only on purpose:
- the AppImage release (`scripts/release-appimage.sh`, `make appimage`);
- the hands-on scripts that unpack it (`basecamp-profile.sh`, `basecamp-local-catalogue.sh`,
  `demo-peer.sh`);
- the `systemd-run` memory cap in the `Makefile`.

People on macOS and Windows install Muster from its catalogue
(`docs/runbooks/install-from-catalogue.md`) into the Basecamp they already run.
