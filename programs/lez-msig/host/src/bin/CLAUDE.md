# programs/lez-msig/host/src/bin/

- `msig_bench`: proves create, fund and an M-signature payment privately, M = 1 3 5 10 by default.
  It prints the host and the times; run it on an idle machine.
- `msig_vectors`: prints the vectors JSON for `module/tests/vectors/lez-msig/vectors.json`. Regenerate
  it when a tag, a type or an encoding changes, and rerun `lez_msig_bytes_test`.
