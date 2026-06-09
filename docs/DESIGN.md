# rules_ci_ir — design

A neutral intermediate representation (IR) for CI pipeline
configuration, with proved-correct translations between

  * **GitLab CI** YAML (`.gitlab-ci.yml`)
  * **GitHub Actions** YAML (`.github/workflows/*.yml`)
  * **Bazel** rule invocations (`sh_test` / `genrule` / `py_test` /
    custom)

The repo is in scaffold state — pinned schemas, Rust workspace
skeleton, Bazel rule stubs, and this design doc are live; the
Lean 4 IR + correctness theorems are placeholders pinned by the
roadmap below.

## Why an IR at all

Direct translations between three pairs of CI/build systems would
require six translators (and grows quadratically as more targets
are added). With a single IR in the middle, we instead need:

  * `N` parsers (one per source format)
  * `N` emitters (one per target format)
  * Theorems about parser/emitter pairs, not about every direction.

A neutral IR also forces a sharp question: *what is a CI
pipeline*, structurally? The translation work depends entirely on
that abstraction holding up across three very different surface
representations.

## What "provably correct" means here

Three increasingly ambitious levels of correctness:

| Level | Claim | Status |
|---|---|---|
| **A. Structural** | Parser is total over valid-schema inputs. Round-trip identity holds modulo normalization: `parse · emit · parse ≡ parse`. DAG invariants preserved: no cycles in `needs` / `dependencies`, every artifact consumer has a producer, every job's stage exists in the `stages` list. | Targeted for v0.1. |
| **B. Bisimulation under abstract semantics** | Define an opaque execution model: a job consumes inputs, runs an unspecified action, produces outputs. Prove `gitlab.exec ≃ ir.exec ≃ github.exec` under that model. Captures scheduling, dependency ordering, artifact flow — but not what `script: [pytest]` actually executes. | v0.3+ goal. |
| **C. Runtime equivalence** | Model bash, the runner environment, container state, network. "Translated YAML exits with the same code as the original." | Explicit non-goal. A research project, not a release. |

The repo commits to level A as a hard guarantee, layers level B as
work progresses, and treats level C as out of scope.

## Lean-as-verifier, not Lean-as-runtime

Two natural ways to integrate Lean 4:

1. **Runtime**: compile the Lean translator binary, run it inside
   Bazel actions at build time. Pro: the proofs cover the actual
   running code. Con: Lean → C compile is slow, deployment story
   is heavy, and rewriting parsers in Lean is high-friction.

2. **Verifier**: Rust is the language of the actual translator;
   Lean formalizes the IR + the spec of each parser / emitter; a
   reference implementation in Lean is *extracted* (or
   hand-mirrored) and proven correct; property-based tests
   fuzz-generate schema-valid inputs and check that the Rust
   translator matches the Lean spec on every input. This is the
   Verus / Creusot model.

We pick **verifier**. The Rust translator is the production
artifact. Lean provides:

  * The IR's algebraic types (canonical reference).
  * Theorems on parser totality, round-trip identity, and
    invariant preservation.
  * Reference implementations for each parser/emitter that the
    Rust code is fuzz-tested against.

The Lean code lives under [`ir/`](../ir/); the Rust workspace
lives under [`translator/`](../translator/). The two are kept in
sync by convention + a TODO-tracked roadmap of "Lean theorem
proved → matching Rust property test landed."

## The IR

The IR is a single algebraic type, designed to be the
least-upper-bound of what GitLab CI and GitHub Actions express.
Sketch (Lean syntax, illustrative):

```lean
structure Job where
  name      : String
  stage     : String                  -- "build", "test", ...
  needs     : List String             -- predecessor job names
  rules     : List Rule               -- when this job is selected
  env       : Map String String       -- key=value
  image     : Option String           -- container reference
  script    : List String             -- shell lines, opaque
  artifacts : List ArtifactSpec
  cache     : List CachePath
  outputs   : Map String String       -- exported step outputs
  publish   : Option Publish          -- ship the build to a hosting surface
  deriving Repr, BEq

inductive Publish where               -- structured publish targets
  | pages (path : String)             -- publish `path` as the repo's Pages site
  deriving Repr, BEq

structure Pipeline where
  stages    : List String             -- ordered phase names
  variables : Map String String
  defaults  : Job                     -- inherited shape
  triggers  : List Trigger            -- which events run the pipeline
  jobs      : List Job
  includes  : List Include            -- cross-pipeline composition
  deriving Repr
```

The IR is *not* the union of every GitLab and GitHub feature —
it's the intersection of what can be translated faithfully. Source
features that fall outside (e.g. GitLab's nested `extends`,
GitHub's `reusable workflows` with secrets-inheritance) are
either:

  * **Lowered to the IR** at parse time when an equivalence
    exists (e.g. `extends` resolved before IR emission).
  * **Emitted as a translation diagnostic** (`unsupported feature
    X at path Y`) when not.

Diagnostics are first-class outputs; a translation that emits
diagnostics is still a translation, but downstream consumers
(the Bazel rule, the registry) can treat them as warnings or
hard errors.

### Pages — the first publish node

`publish` is where the IR earns its keep most visibly: "publish this
directory as the repo's static site" is one intent the two backends
realize with almost nothing in common. A job carrying
`publish := some (.pages "public")` lowers as:

**`gitlab-emit`** — GitLab Pages is a magic job named `pages` whose
`public/` artifact is served (the publish dir is `public/`, or set via
`pages.publish:` on 17.x+):

```yaml
pages:
  stage: pages
  script:
    - <job.script>            # build the site into public/
  artifacts:
    paths: [public]
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

**`github-emit`** — GitHub Pages is a workflow that uploads the directory
as a Pages artifact and deploys it, with the right permissions and
environment:

```yaml
jobs:
  pages:
    runs-on: ubuntu-latest
    permissions: { pages: write, id-token: write }
    environment: github-pages
    steps:
      - run: <job.script>                       # build the site
      - uses: actions/upload-pages-artifact@v3
        with: { path: public }
      - uses: actions/deploy-pages@v4
```

The shared core — `job.script` builds the site, then a directory is
published — is exactly one `Publish.Pages path`. Everything else (the
magic job name + `public/` artifact vs. the upload/deploy actions +
`permissions` + `environment`) is emitter-private. `rules_gitlab`'s
`gitlab_pages_job` macro is the hand-written precursor of the
`gitlab-emit` rendering; promoting it here means a repo authors the
publish *once*, in the neutral IR, and gets both backends.

Structural invariant (level A): at most one job may carry a
`Publish.Pages`, and `gitlab-emit` names that job `pages`.

## Schemas + pinning

We pin the canonical upstream schemas (sha256), refreshed via a
documented workflow:

  * **GitLab CI**:
    `gitlab.com/gitlab-org/gitlab-foss/.../editor/schema/ci.json`
    (already in use by [rules_gitlab](https://github.com/fastverk/rules_gitlab)).
  * **GitHub Actions**:
    `json.schemastore.org/github-workflow.json` (mirror of
    SchemaStore's curated version).

Bazel has no JSON Schema — but each spec-derived rule (in the
style of [rules_cloudformation](https://github.com/fastverk/rules_cloudformation))
exposes a typed attr set that *projects* as a JSON Schema. The
Bazel-emit side translates IR jobs into rule invocations against
a fixed runtime: a small `ci_job(name, script, deps, ...)` Bazel
rule built into this module (see [Bazel emit](#bazel-emit)).

## Translator surface

Implemented in `translator/` as a Cargo workspace with these
crates:

| Crate | What | Status |
|---|---|---|
| `ci-ir` | Pure-Rust IR types + invariants + property test helpers. | scaffold |
| `gitlab-parse` | `.gitlab-ci.yml` → IR. ruamel-yaml-equivalent + custom-tag absorber. | scaffold |
| `github-parse` | `.github/workflows/*.yml` → IR. | roadmap |
| `gitlab-emit` | IR → `.gitlab-ci.yml`. | roadmap |
| `github-emit` | IR → GitHub Actions workflow. | roadmap |
| `bazel-emit` | IR → Bazel rule invocations. Uses `starlark` crate's AST to emit `.bzl`. | roadmap |
| `aggregator` | N members → fleet IR + Markdown similarity report. Subsumes the savvi-side Python aggregator. | scaffold (smoke) |
| `ci-translate-cli` | `ci-translate --from gitlab --to github < input.yml > out.yml`. | roadmap |

## Bazel rule surface

User-facing Bazel rules in [`rules/defs.bzl`](../rules/defs.bzl):

| Rule | Status | What |
|---|---|---|
| `ci_yaml_translate(name, src, from, to)` | stub | Translate a single CI YAML file. `from`/`to` ∈ {`gitlab`, `github`, `bazel`}. |
| `ci_yaml_aggregate(name, members)` | stub | Fleet-wide aggregation + Markdown report (Rust reimplementation of the savvi `ci_analysis` rule). |
| `ci_yaml_diff(name, a, b)` | roadmap | Structural diff of two CI YAMLs at the IR level — catches reordering-only changes vs. real diffs. |

These are stubs that exec the relevant Rust binary from
`@rules_ci_ir_crates`. Once the crates are populated, the stubs
become real.

## Bazel-emit

`bazel-emit` is the trickiest part. The IR's notion of a "job" is
a black-box shell script with explicit deps + artifacts; Bazel's
hermeticity requires either:

1. **Wrap the script as `sh_test`**: `sh_test(name = "<job>",
   srcs = ["<job>.sh"], deps = [...])` where the `deps` are the
   predecessor jobs' outputs. Lossy in the other direction
   (Bazel `deps` are at content-level granularity, but a CI
   `needs:` is at job-completion-level granularity — close enough
   for the structural translation).
2. **Generate scaffold + leave the heavy lifting to humans**: emit
   the dependency wiring and let the user fill in real Bazel rule
   types. Less invasive; more useful as a migration tool.

We start with **(1)** — explicit `sh_test` + `genrule` emission.
The output is a single `<name>.bzl` file consumed by a downstream
`load(...)` in a hand-written `BUILD.bazel`. The Rust `starlark`
crate (https://github.com/facebookexperimental/starlark-rust)
provides AST + pretty-printing so the emitted file is canonical
(stable across rebuilds, easy to diff).

Concrete shape:

```python
# Emitted: //path:bazel_pipeline.bzl
load(
    "@rules_ci_ir//rules/runtime:defs.bzl",
    "ci_job",
)

def my_pipeline():
    ci_job(
        name = "build",
        stage = "build",
        script = ["uv sync", "uv build"],
        image = "registry/savvi-ops:ci-py3.13",
    )
    ci_job(
        name = "test",
        stage = "test",
        needs = ["build"],
        script = ["uv run pytest"],
    )
```

`ci_job` is a thin macro provided by rules_ci_ir's runtime that
expands to a `sh_test` or `genrule` depending on artifacts.

## Roadmap by version

| Version | Adds |
|---|---|
| **0.0.1** *(this)* | Scaffold: design doc, schema pins, Rust workspace skeleton, GitLab parser stub, aggregator stub, Bazel rule stubs. No Lean code yet. |
| **0.1.0** | Working GitLab parser → IR; aggregator Rust binary that replaces the savvi `ci_analysis` Python aggregator (same Markdown report); `ci_yaml_aggregate` rule. |
| **0.2.0** | `github-parse`. GitLab ↔ IR round-trip property tests. |
| **0.3.0** | `gitlab-emit` + `github-emit`. End-to-end `ci-translate --from gitlab --to github` works. Includes the `Publish.Pages` node (IR type landed in 0.0.1) — both emitters render a `pages` publish (see *Pages — the first publish node*). |
| **0.4.0** | `bazel-emit` + the `ci_job` runtime macro. GitLab → Bazel `sh_test` graphs. The neutral `ci_pages(site)` authoring macro lands here, superseding `rules_gitlab`'s `gitlab_pages_job`. |
| **0.5.0** | Lean 4 IR formalization + structural correctness theorems (level A above). Property tests are extracted/mirrored. |
| **0.6.0+** | Bisimulation theorems under abstract semantics (level B). |

## Refresh procedure

Every quarter, re-fetch the pinned schemas:

```sh
curl -fL https://gitlab.com/gitlab-org/gitlab-foss/-/raw/master/app/assets/javascripts/editor/schema/ci.json -o /tmp/gitlab-ci.json
shasum -a 256 /tmp/gitlab-ci.json
# paste into schemas/extensions.bzl

curl -fL https://json.schemastore.org/github-workflow.json -o /tmp/github.json
shasum -a 256 /tmp/github.json
# paste into schemas/extensions.bzl
```

Each pinning bump should be accompanied by a CHANGELOG entry
listing any new schema features and whether they require IR
extensions.
