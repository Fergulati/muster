# programs/lez-msig/core/tests/

One test per rule of the design's §5, plus property tests for R.1 (an action runs iff the APPROVE
weight reaches the threshold) and the nonce window. The tests are append-only: extend them, never
weaken them. RFP S.7's minimums are here: below threshold, R.2, and nothing before create.
