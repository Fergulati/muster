# Building the Logos C++ libraries on a newer nixpkgs, without rebuilding Qt (2026-10-14)

Cost: about an hour of builds, half of it a cascade that would have rebuilt Qt from source.

## Why it came up

exo-607 T1b (ADR-019) moves the standalone Nim app to Qt 6.11.2 from nixos-unstable. The app loads two Logos libraries in its own process, `liblogos_core` and `liblogos_protocol`, and both link Qt (`readelf -d`: `libQt6Core`, `libQt6Network`, `libQt6RemoteObjects`). One process cannot hold two Qt copies, so both are rebuilt on the app's Qt, from the runner's exact revisions (`logos-liblogos` `64de644e`, `logos-protocol` `6401e30a`).

## How the whole tree takes the new nixpkgs

Every Logos flake takes `nixpkgs` from its own `logos-nix` input (`nixpkgs.follows = "logos-nix/nixpkgs"`). So `ui-nim/flake.nix` redirects `inputs.<path>.inputs.logos-nix.inputs.nixpkgs.follows` at each of the 21 `logos-nix` nodes under `logos-liblogos`. The list was generated from `flake.lock`, and the capability module's build tooling was left out, since nothing of it links into `liblogos_core`. Each `logos-nix` keeps its own revision, and only its nixpkgs moves. A dry run (`nix build --dry-run`) then lists exactly what will be built. Check it before every real build.

## What broke on nixos-unstable, and the fix for each

| Break | Cause | Fix (`ui-nim/nix/nixpkgs-app/overrides.nix`) |
|---|---|---|
| `Could not find … "boost_system"` in `logos-protocol`'s CMake | Boost 1.89 removed the compiled `boost_system` library; the pinned CMake asks for it as a component. logos-protocol master has since made it optional. | `boost = boost187`, the runner's own Boost. |
| `'strerror' is not a member of 'std'` in logos-module-loader-qt | fmt 11 stopped including `<cstring>`. The runner linked fmt 10 and spdlog 1.15; unstable has fmt 12 and spdlog 1.17, and no spdlog 1.15. Not the compiler: it fails the same on GCC 14. | `CXXFLAGS = "-include cstring"` on the tree's stdenv (CMake reads `CXXFLAGS` from the environment). |
| (none seen, but the default compiler is GCC 16) | The runner was built with GCC 14.3. | `stdenv = gcc14Stdenv` (14.4). |

## The trap: an overlay rebuilds the world

The first fix was a real overlay, `final: prev: { boost = final.boost187; }`. The build then started compiling glib, cairo, cups, avahi and fontforge from source. Changing `boost` changes everything that depends on it, through systemtap and then glib, and that includes **Qt**. The app would have ended up on a home-built Qt that differs from the cache's, the very thing one-Qt-per-process forbids, after hours of compiling.

**The fix:** the overrides are not an overlay. `nixpkgs-app/default.nix` returns `pkgs // overrides pkgs`, a plain attribute replacement over nixos-unstable's own package set. Nothing in that set is re-evaluated, so Qt, glib and the rest stay the cached builds. The Logos derivations still see the overrides, because their nix files call `pkgs.stdenv.mkDerivation` and name their dependencies as `pkgs.<x>`. A Logos derivation that went through `pkgs.callPackage` would not see them; none does today.

The app itself builds on plain nixos-unstable (`nixpkgs.inputs.upstream`), not on the overridden set. Its derivation hash did not move when the overrides went in, and every library in both processes resolves to the same `qtbase-6.11.2` store path.

## The result

- **The rebuild is small:** 38 Logos derivations, and nothing else.
- **The cross-version check holds** (`scripts/nim-app-core-probe.sh`, 5/5). Sampled from `/proc/<pid>/maps` and scoped to the probe's own `LOGOS_INSTANCE_ID`:
  - the app process maps only `qtbase`/`qtremoteobjects` **6.11.2**;
  - its `logos_host_qt` maps only **6.9.2**.

  `muster_module.health()` still crosses between them. QtRO pins its wire on both sides: protocol `QtRO 2.0` and `QDataStream::Qt_6_2`, in 6.9.2 and 6.11.2 alike.

## Also

- **A relative `path:` flake input** (`nixpkgs.url = "path:./nix/nixpkgs-app"`) is resolved inside the parent tree on Nix 2.34 (`parent: []` in the lock), so edits to it take effect without a re-lock. Its own `flake.lock` still pins upstream, and `default.nix` reads that lock, so the two cannot drift.
- **`pkill -f '<pattern>'` from a tool shell kills that shell** when its own command line contains the pattern, and the rest of the command never runs. Kill by PID, or by a pattern the shell's command line cannot contain.
