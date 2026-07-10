# Changelog

All notable changes to rules_ci. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.1.0 — the yaml-free CI runtime (`//ci`)

Adds `@rules_ci//ci:defs.bzl` — the vendor-neutral runtime a repo expresses its
pipeline in so it can delete `.gitlab-ci.yml` (readiness C2), the complement to
`//project` (the GitLab-CI *generator*):

- `ci_job(name, script | test, stage, needs, image, …)` — a hermetic job.
  `script` (shell lines) → `sh_test`; `test` aliases an existing test /
  `test_suite` (for Bazel-native repos, e.g. `//ci:pr_gates`). `needs` become
  `data` (the structural approximation of a GitLab `needs:` edge).
- `ci_publish(name, artifact, kind, destination|repo/tag/asset, needs)` — a
  side-effecting publish job → an `sh_binary` you `bazel run` (creds from the
  runner env). `kind` ∈ `static_cdn` | `site` | `oci` | `github_release`.
- `ci_pipeline(name, jobs)` — test jobs → a `test_suite(name)` so `bazel test
  //ci:<name>` is the gate; publish jobs → `<name>.pipeline.json`, the machine-
  readable `Build.publish[]` contract the fastverk build-runner replays.
- `//ci:publish_runner.sh` — the reference dispatcher per publish `kind`
  (aws s3 / oras / gh release); a dry-run-safe no-op (`FASTVERK_PUBLISH_DRYRUN=1`
  or missing creds) that logs the intended action.
- `rules_shell` promoted to a non-dev dependency (the runtime expands to
  `sh_test`/`sh_binary`).

## 0.0.1 — initial scaffold

Ships:

- **Design doc** at [`docs/DESIGN.md`](docs/DESIGN.md) covering
  the IR design, the three semantic levels of "provably correct,"
  the Lean-as-verifier (not Lean-as-runtime) integration model,
  and the roadmap through v0.6.0.
- **Pinned upstream JSON Schemas** for GitLab CI
  (gitlab-org/gitlab-foss, sha 1e4a59db…) and GitHub Actions
  (SchemaStore mirror, sha 30e8f011…) via the `ci_schemas`
  module extension.
- **Rust Cargo workspace** under `translator/`:
  - `ci-ir` — neutral IR types + structural validate (cycles,
    dangling needs, stage references).
  - `gitlab-parse` — `.gitlab-ci.yml` → IR with custom-tag
    tolerance (GitLab's `!reference`, `!file`, `!base64`).
  - `ci-aggregator` — fleet IR + Markdown similarity report.
    Direct Rust replacement for savvi's Python ci_analysis
    aggregator.
- **Bazel rule stubs** under `rules/defs.bzl`:
  - `ci_yaml_aggregate(name, members)` — fully working, backed by
    the Rust binary.
  - `ci_yaml_translate(name, src, from_format, to_format)` —
    public API stub. Lands in v0.3.0.
  - `ci_yaml_diff(name, a, b)` — public API stub. Lands in v0.4.0+.
- **Lean 4 placeholder** under `ir/` — formalization + theorems
  land in v0.5.0.
