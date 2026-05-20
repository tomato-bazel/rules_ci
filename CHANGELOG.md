# Changelog

All notable changes to rules_ci_ir. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

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
