# ui-nim/nix/nixpkgs-app — the app's nixpkgs (exo-607 T1b)

nixos-unstable plus a few overrides. `ui-nim/flake.nix` uses this flake as its `nixpkgs` and makes every Logos input under `logos-liblogos` follow it, so the app's Qt (6.11.2) and the two Logos libraries the app loads in-process, `liblogos_core` and `liblogos_protocol`, come from one nixpkgs. One process cannot hold two Qt copies (ADR-019).

- **`default.nix` is what `import nixpkgs { … }` reaches.** The Logos flakes take their pkgs that way, so the overrides reach them too. It reads upstream from this flake's own `flake.lock`. Bump the rev in `flake.nix`, run `nix flake lock` here and then `nix flake update nixpkgs` in `ui-nim/`.
- **`overrides.nix` is only for what the Logos tree needs to build on this nixpkgs** (GCC 14, Boost 1.87: the runner's own). It replaces attributes and is not an overlay, so nothing else rebuilds, and Qt stays the cache's build. A true overlay that changed `boost` or `stdenv` would rebuild Qt from source and leave the app on a different Qt. Each entry says why and when to drop it. Do not use it to pin the app's own dependencies.
