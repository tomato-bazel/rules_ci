# Changelog

All notable changes to rules_ci. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.2.1 — `ci_job(test = ...)` no longer produces an empty gate

`ci_job(test = X)` built `test_suite(tests = [X], tags = ["ci-job", "ci-stage=…"])`,
and a `test_suite`'s tags FILTER its direct members. No ordinary test carries
`ci-job`, so the suite resolved to EMPTY and `bazel test //ci:<job>` passed having
run nothing.

That is the worst failure mode a gate has: it does not break, it reports green
while verifying nothing — and it did so for exactly the targets people name
explicitly as jobs, which tend to be the security-shaped ones. Found in aion/graph
(`//ci:graph_server_tests` → 0 tests, guarding a deprovision blast radius) and
aion/idp (`//ci:unit` → 0 tests).

It hid because a job aliasing something that was ITSELF a `test_suite` expanded
correctly — nested suites are expanded, not filtered — so the breakage looked
target-specific. Every in-repo example used `script =`, so the alias path was
never exercised.

- `ci_job(test = ...)` now routes the aliased target through an untagged inner
  `<name>.tests` suite; the outer suite keeps `job_tags` for introspection / the
  IR round-trip. NB the generated `<name>.tests` name is new and can collide.
- `ci_job(test = ...)` now also GENERATES `<name>.not_vacuous_test`, a per-job
  gate asserting the job expands to ≥1 test. The fix above removes the cause we
  know about, not the failure mode: a `test_suite` with no matching members
  resolves to nothing rather than erroring, so aliasing an empty suite still
  yields a job that passes having run zero tests. Vacuity is invisible in
  `bazel test` output and in `pipeline.json` (which records job labels, not the
  tests behind them), so nothing else here can notice it. Per-job, not
  per-pipeline: `tests(<pipeline>)` is non-empty as long as ANY job has tests, so
  a pipeline-wide check cannot localize — or even detect — one hollow job among
  several. Opt out with `vacuity_gate = False`. `script =` jobs get no gate;
  they cannot be vacuous.
- Verified both directions: the gate FAILS (naming the job) against the pre-fix
  macro and passes after.

## 0.2.0 — `ci_publish(kind = "npm")`

Adds `npm` to `PUBLISH_KINDS`, so a repo that publishes an npm package can go
yaml-free. Until now `ci_publish` covered `static_cdn` | `site` | `oci` |
`github_release`, which meant any repo whose deliverable is an npm package had to
keep a `.gitlab-ci.yml` purely to run `npm publish` — the exact thing `//ci`
exists to delete. First consumer: aion/sql, whose `@aion/db-migrations-sql`
(the aion golden-schema `migrations.zip`, consumed by studio/web) lost its only
publish lane when the repo went fastverk-only.

- `ci_publish(name, artifact = <npm tarball>, kind = "npm", destination = <registry url>)`.
  `artifact` is an `npm pack`-layout tarball (a `package/` root); `destination`
  is the registry URL, e.g.
  `https://gitlab.example.com/api/v4/projects/<id>/packages/npm/`.
- Auth from the runner env, first match wins: `NPM_TOKEN`, `GITLAB_NPM_TOKEN`,
  `CI_JOB_TOKEN`, `GITLAB_TOKEN`. A temporary `NPM_CONFIG_USERCONFIG` carries the
  `_authToken` line keyed by the registry's scheme-less URI prefix (how npm
  matches auth).
- **Idempotent**: a published version is immutable, so the runner skips when the
  exact `name@version` already exists rather than failing — re-running a pipeline
  on an unbumped commit is a no-op. This preserves the `publish.mjs` convention
  the GitLab jobs used. `name`/`version` are read out of the tarball's
  `package/package.json` with `node` (which ships with `npm`, so no new dep).
- No credentials, or `FASTVERK_PUBLISH_DRYRUN=1` → logs the intended publish and
  exits 0, like every other kind.

No IR/proto change: `pipeline.json` already carries `kind` as an opaque string.

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
