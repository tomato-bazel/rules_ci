#!/usr/bin/env bash
# Asserts that the non-gitlab CI backends generate NO pipeline-FILE targets.
#
# WHY A TEST AND NOT A COMMENT. This package already claimed, in prose, that "NO
# .gitlab-ci.yml is written anywhere by this target" — and that claim is the whole
# point of the `ci` backend: readiness criterion C2 (`ci-as-rules`) requires the
# forge-native file to be ABSENT. A comment cannot fail CI. If `ci = "native"` or
# `ci = "none"` ever started emitting the pipeline file again, every repo that had
# "migrated" would still be carrying one, C2 would read as satisfied while being
# false, and nothing would go red. Same reasoning as plugin-forge's vendored-proto
# drift gate.
#
# WHAT COUNTS AS A PIPELINE-FILE TARGET. Not simply "anything named .ci" —
# `ci = "native"` deliberately generates `<name>.ci` (the test_suite) and
# `<name>.ci.manifest` (publish jobs for the build-runner), and those SHOULD exist.
# The forbidden ones are the artifacts of generating a `.gitlab-ci.yml`:
#
#   <name>.ci.update        the writer
#   <name>.ci.update_test   its drift gate
#   <name>.ci_validate      its schema gate
set -euo pipefail

targets_file="${TARGETS:?TARGETS must point at the genquery output}"

if [[ ! -s "$targets_file" ]]; then
  echo "FAIL: target list is empty — the genquery produced nothing, so this proved nothing." >&2
  exit 1
fi

if offenders=$(grep -E ':(project|project_none)\.(ci\.update|ci_validate)' "$targets_file"); then
  echo "FAIL: a non-gitlab CI backend generated pipeline-file targets:" >&2
  echo "$offenders" >&2
  echo "C2 (ci-as-rules) requires the forge-native pipeline file to be ABSENT." >&2
  exit 1
fi

# Positive half: what must SURVIVE. `ci = "native"` keeps a real gate, and
# `ci = "none"` must still ANALYZE — the dangling `.ci.update_test` in the gates
# list is exactly what used to make the "none" shape impossible.
for required in ':project.ci_gates' ':project_none.ci_gates'; do
  if ! grep -q -- "$required" "$targets_file"; then
    echo "FAIL: $required is missing — the backend dropped more than the pipeline file." >&2
    cat "$targets_file" >&2
    exit 1
  fi
done

echo "ok: no pipeline-file targets; the native gate suite and the ci=none shape both survive"
