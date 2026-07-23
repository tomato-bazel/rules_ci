#!/usr/bin/env bash
# Asserts that `ci_job(test = X)` produces a suite that actually CONTAINS X.
#
# WHY A TEST AND NOT A COMMENT. `ci_job`'s `test =` branch builds a test_suite
# tagged `ci-job` / `ci-stage=<stage>`, and a test_suite's tags FILTER its direct
# members. No ordinary test carries those tags, so the suite resolved to EMPTY and
# `bazel test //ci:<job>` reported green having run nothing — a gate that cannot
# fail is worse than no gate, because it is counted as coverage.
#
# It hid because a job aliasing something that was ITSELF a test_suite expanded
# correctly (nested suites are expanded, not filtered), so the breakage looked
# target-specific. This asserts the general property on the shape that broke: an
# aliased test carrying its own unrelated tags.
set -euo pipefail

tests_file="${TESTS:?TESTS must point at the genquery output}"

if [[ ! -s "$tests_file" ]]; then
  echo "FAIL: ci_job(test = ...) expanded to NO tests." >&2
  echo "The job suite is vacuous: 'bazel test' on it passes having run nothing." >&2
  echo "Cause: a test_suite's tags filter its direct members; route the aliased" >&2
  echo "target through an untagged inner suite (see ci/defs.bzl)." >&2
  exit 1
fi

if ! grep -q 'tagged_unit_test' "$tests_file"; then
  echo "FAIL: the aliased test is missing from the job suite:" >&2
  cat "$tests_file" >&2
  exit 1
fi

echo "ok: ci_job(test = ...) contains its aliased test ($(wc -l < "$tests_file" | tr -d ' ') target(s))"
