# shellcheck shell=bash
# Spellings that hold on Linux and on macOS, for scripts that run on both. Sourced, never
# executed. macOS has bash 3.2 (/bin/bash, which `#!/usr/bin/env bash` finds there) and
# Darwin's tools: no `declare -A`, no "${a[@]}" of an empty array under `set -u` (write
# ${a[@]+"${a[@]}"}), Darwin's `sha256sum -c` reads a check list from stdin only when given
# `-`, and older macOS has no sha256sum at all (shasum is on every macOS).

# lgx_variant — the .lgx variant this host's .#lgx-portable carries, as lgpm looks it up:
# linux-amd64, linux-arm64 or darwin-arm64. Any other host fails, an Intel Mac included:
# no Intel build has shown which spelling its manifest carries. A shell under Rosetta reads
# x86_64 from uname on an Apple Silicon Mac whose nix still builds darwin-arm64, so ask the
# kernel. A caller still checks the built manifest against this.
lgx_variant() {
  local s m
  s=$(uname -s); m=$(uname -m)
  if [ "$s/$m" = Darwin/x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then m=arm64; fi
  case "$s/$m" in
    Linux/x86_64)              echo linux-amd64 ;;
    Linux/aarch64|Linux/arm64) echo linux-arm64 ;;
    Darwin/arm64)              echo darwin-arm64 ;;
    *) echo "lgx_variant: no .lgx variant for $s $m" >&2; return 1 ;;
  esac
}

# sha256_of FILE — its sha256, in hex. GNU and Darwin sha256sum print the same line; a Mac
# without sha256sum still has shasum. Read from stdin, so no file name is ever escaped into
# the output.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum <"$1"; else shasum -a 256 <"$1"; fi | cut -c1-64
}
