#!/usr/bin/env python3
"""No C or C++ in the repo, outside two directories exempted by name (exo-607 T7, ADR-019).

Jacek's success criterion for the seaqt work: "it works, with no C++ code in the repo".
The native code is Nim. C++ that a build GENERATES (seaqt's wrappers, the Logos builder's
plugin glue) is fine: it never reaches the tree. This gate keeps hand-written C/C++ from
coming back unnoticed.

  FAIL  a tracked C or C++ source or header outside the exemptions below

The exemptions, each with the reason it exists and when it ends:

  ui/    the Basecamp build of the UI (muster_ui as a Logos ui_qml plugin), kept frozen
         because the catalogue, the platform Signer and the Monero campaign ship through
         it. It ends when ui-host can load a Nim plugin cleanly (docs/design/seaqt-ui.md
         §9 T4b) and the Basecamp UI is the Nim one.
  demo/  the speed build, deliberately not the specified client (the operator,
         2026-10-14).

Build configuration (CMakeLists.txt, which the Logos module builder requires) is not
source and is not checked. Text-only and pre-commit cheap: it reads `git ls-files`.

  scripts/check-no-cpp.py              # the tracked tree
  scripts/check-no-cpp.py PATH…        # these paths instead (how its test proves it fails)
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

SOURCE_SUFFIXES = {
    ".c", ".h",                                          # C (and headers either language uses)
    ".cpp", ".cc", ".cxx", ".c++", ".C",                 # C++ sources
    ".hpp", ".hh", ".hxx", ".h++", ".ipp", ".tpp", ".inl",  # C++ headers and inline parts
    ".m", ".mm",                                         # Objective-C/C++
}

EXEMPT = {
    "ui/": "the frozen Basecamp UI build, until ui-host takes a Nim plugin (ADR-019)",
    "demo/": "the speed build, not the client (operator, 2026-10-14)",
}


def is_source(path: str) -> bool:
    p = Path(path)
    return p.suffix in SOURCE_SUFFIXES or p.suffix.lower() in SOURCE_SUFFIXES - {".C"}


def exemption(path: str) -> str | None:
    for prefix in EXEMPT:
        if path.startswith(prefix):
            return prefix
    return None


def check(paths: list[str]) -> list[str]:
    return [f"FAIL  C/C++ outside the exemptions: {p}"
            for p in paths if is_source(p) and exemption(p) is None]


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files"], cwd=REPO_ROOT, check=True,
                         capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def main(argv: list[str]) -> int:
    paths = argv or tracked()
    failures = check(paths)
    for f in failures:
        print(f)
    if failures:
        print(f"{len(failures)} C/C++ file(s) outside {', '.join(EXEMPT)}: write it in Nim, "
              "or generate it at build time (docs/design/seaqt-ui.md, ADR-019).")
        return 1
    exempt = sum(1 for p in paths if is_source(p))
    print(f"no C/C++ outside {', '.join(EXEMPT)} ({exempt} exempt file(s) in them).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
