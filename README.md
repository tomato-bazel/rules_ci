# rules_ci_ir

Bazel rules + a Rust translator stack for moving CI pipeline
configuration between **GitLab CI**, **GitHub Actions**, and
**Bazel** — mediated by a neutral IR with Lean 4 correctness
theorems.

> **Status**: v0.0.1 scaffold. Pinned schemas, working GitLab
> CI parser + Rust aggregator binary, Bazel rule stubs, and a
> comprehensive design doc are live. GitHub-parse, the emit-side
> translators, the `bazel-emit` macro layer, and the Lean
> formalization are roadmap items — see
> [`docs/DESIGN.md`](docs/DESIGN.md).

## Quick start (today)

```python
# MODULE.bazel
bazel_dep(name = "rules_ci_ir", version = "0.0.1")
```

```python
# BUILD.bazel
load("@rules_ci_ir//rules:defs.bzl", "ci_yaml_aggregate")

ci_yaml_aggregate(
    name = "fleet_report",
    members = {
        "service-a": "//path/to/service-a:.gitlab-ci.yml",
        "service-b": "//path/to/service-b:.gitlab-ci.yml",
    },
)
```

```sh
bazel build //path:fleet_report
# bazel-bin/path/fleet_report.fleet.json — normalized IR projection
# bazel-bin/path/fleet_report.fleet.md   — Markdown similarity matrix
```

The aggregator is a Rust binary (under `translator/aggregator`)
that parses each member's `.gitlab-ci.yml`, normalizes through
the `ci-ir` IR, and emits both a machine-readable projection and a
Markdown report covering: stages × member matrix, cross-project
`include:` references, jobs in multiple members, variables in
multiple members, and per-member counts.

## What's coming

| Version | Adds | Why |
|---|---|---|
| **0.1.0** | Property tests on `gitlab-parse` round-trip. `ci_yaml_translate` for the trivial direction (parse → re-emit). | Foundation. |
| **0.2.0** | `github-parse` (`.github/workflows/*.yml` → IR). | Both source formats can be ingested. |
| **0.3.0** | `gitlab-emit` + `github-emit` — true cross-format translation. | The headline feature. |
| **0.4.0** | `bazel-emit` — IR jobs become `sh_test` + `genrule` targets via the `starlark` Rust crate's AST. | Bazel as a third translation target. |
| **0.5.0** | Lean 4 IR formalization + structural correctness theorems (parser totality, round-trip identity, DAG invariant preservation). | Mathematically grounded translations. |
| **0.6.0+** | Bisimulation theorems under an abstract execution semantics. | Scheduling / dep-ordering proved equivalent. |

The full architecture and proof strategy is in
[`docs/DESIGN.md`](docs/DESIGN.md).

## Layout

```
docs/DESIGN.md           # architecture + proof strategy
schemas/extensions.bzl   # sha-pinned upstream JSON Schemas (gitlab + github)
ir/                      # Lean 4 IR (placeholder; lands v0.5.0)
translator/              # Cargo workspace
  ci-ir/                   # IR types + invariants
  gitlab-parse/            # .gitlab-ci.yml → IR
  aggregator/              # Rust ci_aggregator binary
  # github-parse, gitlab-emit, github-emit, bazel-emit per roadmap
rules/defs.bzl           # Bazel rules: ci_yaml_aggregate (live),
                         # ci_yaml_translate, ci_yaml_diff (stubs)
```

## Provenance + alternatives

The IR + verifier-side proofs approach is closer in spirit to
[Verus](https://github.com/verus-lang/verus) and
[Creusot](https://github.com/creusot-rs/creusot) than to
[Earthly](https://earthly.dev/) or [Dagger](https://dagger.io/),
which solve the same "portable CI" problem at runtime via their
own DSLs. Earthly/Dagger are great for green-field projects.
This repo targets the boring-but-real case: an org with 5–50
existing GitLab pipelines needs to migrate to GitHub Actions
without losing semantic fidelity. The Lean proofs are the
distinguishing claim — when the translator says "no diagnostics,"
it really preserves the structural invariants.
