{
  # The app's nixpkgs (exo-607 T1b, ADR-019): nixos-unstable, plus the few overrides the
  # Logos C++ tree needs to build on it (overrides.nix). ui-nim/flake.nix makes every
  # Logos input under liblogos follow this flake as its nixpkgs, so they reach all of them.
  description = "nixos-unstable plus the overrides the Logos C++ tree needs on it";

  inputs.upstream.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";

  outputs = { self, upstream }: {
    lib = upstream.lib;
    legacyPackages = upstream.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
      (system: import ./default.nix { inherit system; });
  };
}
