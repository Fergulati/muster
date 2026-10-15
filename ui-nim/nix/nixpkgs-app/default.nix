# `import nixpkgs { … }` on this flake lands here, because a flake input's outPath is its
# source tree. That is how the Logos flakes take their pkgs, so the overrides reach them.
# Upstream comes from this flake's own lock, so the two cannot drift.
args:
let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  upstream = builtins.fetchTree lock.nodes.upstream.locked;
  pkgs = import upstream args;
in
pkgs // import ./overrides.nix pkgs
