#!/usr/bin/env bash
# Asserts that a `ci_job(test = ...)` expands to at least one test.
#
# A CI gate that runs nothing is worse than no gate: it cannot fail, and it is
# counted as coverage while verifying nothing. Vacuity is invisible in `bazel
# test` output (an empty suite is reported exactly like a passing one) and
# invisible in <pipeline>.pipeline.json (which records job labels, not the tests
# behind them), so nothing else in this ruleset can notice it.
#
# Known ways a job goes empty:
#   * a test_suite's `tags` FILTER its direct members, so a tagged job suite drops
#     any aliased test that does not carry those tags (fixed in ci_job, and this
#     gate is what keeps it fixed);
#   * aliasing a test_suite that is itself empty — no error, just nothing.
set -euo pipefail

tests_file="${TESTS:?TESTS must point at the genquery output}"
job="${JOB:-<unknown>}"

if [[ ! -s "$tests_file" ]]; then
  cat >&2 <<MSG
FAIL: ci_job '$job' expands to NO tests.

The job's test_suite is empty, so \`bazel test\` on it passes having run nothing.
Check what it aliases: an empty test_suite, or a test filtered out by tags.
Set \`vacuity_gate = False\` on the job only if it is deliberately allowed to be
empty.
MSG
  exit 1
fi

echo "ok: ci_job '$job' expands to $(grep -c . "$tests_file") test target(s)"
