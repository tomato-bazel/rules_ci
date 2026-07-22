# rules_ci

The fastverk **CI / release / versioning** foundation: generate a repo's CI pipeline by
convention, make its shippable **products** first-class in the build graph, **drift-gate** its
generated files, drive **automated versioning** from the public surface — plus a Rust **CI-IR
translator** (GitLab ↔ GitHub ↔ Bazel, mediated by a neutral IR).

> **This README is GENERATED — do not edit it directly.** The API reference below is rendered
> from the `.bzl` docstrings by **stardoc**; the whole file is composed by **rules_readme** and
> drift-gated by `//:readme.write_test` (run in CI + the pre-commit hook). To change it, edit the
> `.bzl` docstrings or `README.md.tmpl`, then run `bazel run //:readme.write`.



## The three-layer spine

`fastverk_project` (this module) ← `aion_framework_library` (aion/rules) ← `aion_app` (studio).
A repo calls the one macro for its layer; it composes the CI pipeline (rules_gitlab `gitlab_ci`),
the README badges (rules_readme), the `release_artifacts` products aspect, the `git_hooks`
pre-commit installer, and the `version/` tooling — all from convention.

## Quick start

```python
# MODULE.bazel
bazel_dep(name = "rules_ci", version = "0.0.1")
```

```python
# BUILD.bazel — generate + drift-gate this repo's .gitlab-ci.yml, README badges, and hooks
load("@rules_ci//project:defs.bzl", "fastverk_project")

fastverk_project(name = "project", repo = "your/repo", badges = True, hooks = True)
```

```sh
bazel test //:project.ci_gates       # every drift/validation gate (CI + the pre-commit hook)
bazel run  //:project.hooks_install  # install the pre-commit hook (core.hooksPath)
```

## API reference

<!-- Generated with Stardoc: http://skydoc.bazel.build -->

fastverk_project — the generic per-repo convention macro (the fastverk layer).

Composes the project-level wiring a repo needs — CI, README/badges, git hooks,
versioning — from the underlying rulesets (rules_gitlab, rules_readme), driven by the
products the `//release:release_artifacts` aspect discovers in the build graph. The upper
layers wrap this: aion/rules' `aion_framework_library` / `aion_framework_project`, and
studio's `aion_app(features = [...])`.

Milestone 1: the `.gitlab-ci.yml` generator — emit + schema-validate + drift-gate a thin
pipeline from a caller-supplied `include:` + CI variables.

Milestone 4 (this revision): `ci =` selects the CI BACKEND, so the pipeline file stops
being mandatory. The macro previously called `gitlab_ci()` unconditionally, which put it
in direct contradiction with readiness criterion C2 (`ci-as-rules` requires the
forge-native CI file to be ABSENT) — C2 was unsatisfiable for every repo using this macro.
`ci = "native"` composes `//ci`'s `ci_job`/`ci_publish` targets instead and writes no such
file; `ci = "none"` wires no CI at all.

Milestone 3 (this revision): `features` + the release-products gate. A *feature* is a
named bundle of (CI lane include(s), CI variables, expected shippable products). The
upper layers own the feature CATALOG — studio's `aion_app(features = ["web", "tui"])`
resolves names → the resolved `features` dict this macro consumes — so the generic layer
stays catalog-agnostic. When the repo points `products` at its top-level product targets,
the macro materializes the discovered-products manifest and, against the declared set, a
declared-vs-discovered DRIFT GATE (`products_drift_test`) — the connection between the
features a repo turns on and the artifacts it's allowed to ship.

Badges, git hooks, and the versioning workflow land in subsequent milestones.

<a id="fastverk_project"></a>

## fastverk_project

<pre>
load("@rules_ci//project:defs.bzl", "fastverk_project")

fastverk_project(<a href="#fastverk_project-name">name</a>, <a href="#fastverk_project-repo">repo</a>, <a href="#fastverk_project-ci_include">ci_include</a>, <a href="#fastverk_project-ci_variables">ci_variables</a>, <a href="#fastverk_project-ci_stages">ci_stages</a>, <a href="#fastverk_project-ci_jobs">ci_jobs</a>, <a href="#fastverk_project-ci_extra">ci_extra</a>, <a href="#fastverk_project-ci">ci</a>,
                 <a href="#fastverk_project-ci_jobs_native">ci_jobs_native</a>, <a href="#fastverk_project-features">features</a>, <a href="#fastverk_project-products">products</a>, <a href="#fastverk_project-expected_products">expected_products</a>, <a href="#fastverk_project-gate_tests">gate_tests</a>, <a href="#fastverk_project-hooks">hooks</a>, <a href="#fastverk_project-hooks_dir">hooks_dir</a>,
                 <a href="#fastverk_project-badges">badges</a>, <a href="#fastverk_project-host">host</a>, <a href="#fastverk_project-badge_branch">badge_branch</a>, <a href="#fastverk_project-write_to">write_to</a>, <a href="#fastverk_project-validate">validate</a>, <a href="#fastverk_project-visibility">visibility</a>)
</pre>

Generic project-level wiring: the CI backend + the release-products gate.

With `ci = "gitlab"` (the default), generates `<write_to>` and its gates:

    bazel run  //:<name>.ci.update           # (re)generate the pipeline into the tree
    bazel test //:<name>.ci.update_test      # CI-drift gate (CI + the pre-commit hook)
    bazel build //:<name>.ci_validate        # schema gate

With `ci = "native"`, no forge-native file is written — CI is Bazel targets:

    bazel test //:<name>.ci                  # the test gate (a test_suite)
    # <name>.ci.pipeline.json                # publish jobs, read by the build-runner

With `ci = "none"`, neither.

And, when `products` is set, the release-products seam:

    bazel build //:<name>.products           # the discovered-products JSON manifest
    bazel test  //:<name>.products_drift_test # declared-vs-discovered drift gate

Plus the unified gate suite (and, with `hooks = True`, the installer):

    bazel test //:<name>.ci_gates            # every drift/validation gate (CI + the hook)
    bazel run  //:<name>.hooks_install       # install the pre-commit hook (core.hooksPath)


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="fastverk_project-name"></a>name |  base name; generates `<name>.ci`, `<name>.ci.update`, `<name>.ci_validate`, and (when `products` is set) `<name>.products` + `<name>.products_drift_test`.   |  `"project"` |
| <a id="fastverk_project-repo"></a>repo |  OWNER/REPO on the git host (e.g. "aion/db"). Used for the README badges.   |  `None` |
| <a id="fastverk_project-ci_include"></a>ci_include |  base GitLab `include:` entries (list of dicts) — shared lane(s) to pull in. `ci = "gitlab"` only.   |  `[]` |
| <a id="fastverk_project-ci_variables"></a>ci_variables |  base global CI/CD variables (dict). `ci = "gitlab"` only.   |  `{}` |
| <a id="fastverk_project-ci_stages"></a>ci_stages |  explicit pipeline stages (usually empty — the included lane owns them). `ci = "gitlab"` only.   |  `[]` |
| <a id="fastverk_project-ci_jobs"></a>ci_jobs |  repo-local jobs (usually empty — jobs live in the shared lane). `ci = "gitlab"` only.   |  `{}` |
| <a id="fastverk_project-ci_extra"></a>ci_extra |  escape-hatch raw top-level keys merged into the generated pipeline. `ci = "gitlab"` only.   |  `{}` |
| <a id="fastverk_project-ci"></a>ci |  which CI backend to generate — one of `CI_BACKENDS`:<br><br>* `"gitlab"` (default) — a generated `.gitlab-ci.yml`. Unchanged behavior. * `"native"` — CI as `ci_job`/`ci_publish` Bazel targets, NO forge-native   file. This is what makes readiness criterion C2 (`ci-as-rules`, which   requires `.gitlab-ci.yml` to be absent) satisfiable — it was previously   unreachable for any repo using this macro, because the macro always   emitted the very file C2 forbids. `bazel test //:<name>.ci` is the gate. * `"none"` — no CI wiring, for a repo built entirely off the BuildRun rail.<br><br>The GitLab-shaped args (`ci_include`, `ci_variables`, `ci_stages`, `ci_jobs`, `ci_extra`) configure a generated pipeline FILE; passing them with a non-gitlab backend is an error rather than a silent no-op, so a repo flipping to `"native"` cannot quietly drop its lanes.   |  `"gitlab"` |
| <a id="fastverk_project-ci_jobs_native"></a>ci_jobs_native |  `ci_job()` / `ci_publish()` results composed into the pipeline when `ci = "native"`. Test jobs become the `<name>.ci` test_suite; publish jobs land in `<name>.ci.pipeline.json` for the build-runner.   |  `[]` |
| <a id="fastverk_project-features"></a>features |  resolved feature bundles, `{name: {"include": [...], "variables": {...}, "jobs": {...}, "expects": [{"kind","name"}, ...]}}`. Enabling a feature = its presence here; its `include`/`variables`/`jobs` union onto the base CI, and its `expects` join the declared product set for the drift gate. The upper layers turn `["web", "tui"]` into this dict; the generic layer never hardcodes which features exist. A sibling product ruleset can EXPORT a helper returning such a bundle (e.g. rules_tap's affected-test lane as inline `jobs`) — so fastverk_project composes it WITHOUT a hard dep on that ruleset. Example:<br><br>    load("@rules_tap//ci:defs.bzl", "tap_ci_feature")     fastverk_project(name = "project", repo = "aion/db",                      features = {"tap": tap_ci_feature()})  # adds the affected-test lane   |  `{}` |
| <a id="fastverk_project-products"></a>products |  top-level product targets (labels) to run the `release_artifacts` aspect over — the inputs to the manifest + drift gate. Empty ⇒ no release-products targets.   |  `[]` |
| <a id="fastverk_project-expected_products"></a>expected_products |  products the repo declares it ships, as `[{"kind","name"}, ...]` (merged with every enabled feature's `expects`). Drives the drift gate; empty (and no feature expects) ⇒ the manifest is still emitted but no gate is generated.   |  `[]` |
| <a id="fastverk_project-gate_tests"></a>gate_tests |  EXTRA gate test labels to fold into `<name>.ci_gates` (e.g. the repo's `:readme.write_test`, a lockfile drift test, a manifest `objects.json` gate). The macro's own gates (`.ci.update_test`, `.products_drift_test`) are added automatically.   |  `[]` |
| <a id="fastverk_project-hooks"></a>hooks |  also generate `<name>.hooks_install` — `bazel run` it to install a pre-commit hook that runs `<name>.ci_gates` (hard block, no auto-fix) + sets `core.hooksPath`. Local/CI parity: the hook runs the SAME suite as CI. Default off.   |  `False` |
| <a id="fastverk_project-hooks_dir"></a>hooks_dir |  working-tree dir the pre-commit hook is installed into (default ".githooks").   |  `".githooks"` |
| <a id="fastverk_project-badges"></a>badges |  emit a `<name>.badges` rules_readme `markdown_fragment` (slot "badges") with the GitLab-native pipeline + coverage badges for `repo`. The repo's README template composes it: `<!-- FRAGMENTS:badges -->` + `readme(fragments=[":<name>.badges"])`. Requires `repo`. Default off (opt-in until a repo wires the slot).   |  `False` |
| <a id="fastverk_project-host"></a>host |  the git host for the badge URLs (default "gitlab.savvifi.com").   |  `"gitlab.savvifi.com"` |
| <a id="fastverk_project-badge_branch"></a>badge_branch |  the branch the badges reflect (default "main").   |  `"main"` |
| <a id="fastverk_project-write_to"></a>write_to |  source-relative output path (default `.gitlab-ci.yml`).   |  `".gitlab-ci.yml"` |
| <a id="fastverk_project-validate"></a>validate |  schema-validate the generated file (default True).   |  `True` |
| <a id="fastverk_project-visibility"></a>visibility |  target visibility for the generated targets.   |  `None` |

<!-- Generated with Stardoc: http://skydoc.bazel.build -->

release_artifacts — make the build graph's "versioned products" first-class.

A `ReleaseArtifactInfo` is the normalized, cross-kind view of a shippable product (an npm
package, an OCI image, a helm chart, a static site, an aion module bundle). The
`release_artifacts` aspect SYNTHESIZES it from the producing rules rather than requiring
producers to hand-emit it — so any existing `npm_package` / `oci_image` / … is
discoverable as a product automatically.

`fastverk_project` consumes the aspect to derive a repo's products → which CI lanes to
include and what the versioning workflow operates on. `kind` is thus DERIVED from what a
repo produces, not declared.

Detection keys off `ctx.rule.kind` — a stable signal that avoids depending on
aspect_rules_js/ts internal provider symbols (whose fields shift across versions). The
public-surface extraction for versioning (npm → the `.d.ts` via rules_ts `DeclarationInfo`;
the package name/version via the package.json) is pinned when the aspect is first run
against a real package — see the M3 TODOs below.

<a id="products_drift_test"></a>

## products_drift_test

<pre>
load("@rules_ci//release:defs.bzl", "products_drift_test")

products_drift_test(<a href="#products_drift_test-name">name</a>, <a href="#products_drift_test-deps">deps</a>, <a href="#products_drift_test-expected">expected</a>)
</pre>

Fail if the products discovered under `deps` differ from the declared `expected` set.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="products_drift_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="products_drift_test-deps"></a>deps |  Top-level targets whose discovered products are checked against `expected`.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="products_drift_test-expected"></a>expected |  Declared products as normalized "kind:name" entries (e.g. "npm:@aion/foo").   | List of strings | optional |  `[]`  |


<a id="release_manifest"></a>

## release_manifest

<pre>
load("@rules_ci//release:defs.bzl", "release_manifest")

release_manifest(<a href="#release_manifest-name">name</a>, <a href="#release_manifest-deps">deps</a>)
</pre>

Emit the fastverk.release.v1.ReleaseManifest (proto3-JSON) of every product under `deps`.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="release_manifest-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="release_manifest-deps"></a>deps |  Top-level targets to discover products under.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |


<a id="ReleaseArtifactInfo"></a>

## ReleaseArtifactInfo

<pre>
load("@rules_ci//release:defs.bzl", "ReleaseArtifactInfo")

ReleaseArtifactInfo(<a href="#ReleaseArtifactInfo-kind">kind</a>, <a href="#ReleaseArtifactInfo-name">name</a>, <a href="#ReleaseArtifactInfo-label">label</a>, <a href="#ReleaseArtifactInfo-version_source">version_source</a>, <a href="#ReleaseArtifactInfo-surface">surface</a>)
</pre>

Normalized view of one shippable, versioned product discovered in the graph.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ReleaseArtifactInfo-kind"></a>kind |  Product kind: npm \| oci \| helm \| site \| module_bundle.    |
| <a id="ReleaseArtifactInfo-name"></a>name |  The product's published name (npm package name, image repo, chart name).    |
| <a id="ReleaseArtifactInfo-label"></a>label |  The Bazel label that produces it (string).    |
| <a id="ReleaseArtifactInfo-version_source"></a>version_source |  Where the version is read (e.g. the package.json File), or None.    |
| <a id="ReleaseArtifactInfo-surface"></a>surface |  Tuple of Files describing the public surface for versioning (npm: the .d.ts* closure); () if none.    |


<a id="ReleaseArtifactsInfo"></a>

## ReleaseArtifactsInfo

<pre>
load("@rules_ci//release:defs.bzl", "ReleaseArtifactsInfo")

ReleaseArtifactsInfo(<a href="#ReleaseArtifactsInfo-products">products</a>)
</pre>

Aggregate of every ReleaseArtifactInfo reachable from a target.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ReleaseArtifactsInfo-products"></a>products |  depset of ReleaseArtifactInfo.    |


<a id="release_artifacts"></a>

## release_artifacts

<pre>
load("@rules_ci//release:defs.bzl", "release_artifacts")

release_artifacts()
</pre>

Walk a target's graph and collect its shippable products as ReleaseArtifactInfo.

**ASPECT ATTRIBUTES**


| Name | Type |
| :------------- | :------------- |
| deps| String |
| srcs| String |
| data| String |


**ATTRIBUTES**

<!-- Generated with Stardoc: http://skydoc.bazel.build -->

git_hooks — install a pre-commit hook that runs the SAME gates as CI.

The local/CI parity rule: a developer's pre-commit runs exactly the `ci_gates` test_suite
that CI runs — so a commit that would fail the pipeline's drift/validation gates (stale
generated `.gitlab-ci.yml`, README, products manifest, lockfiles, …) is blocked locally
FIRST. Hard block, NO auto-fix: the dev runs the named `.update`/`.write` target and
re-commits. `fastverk_project(hooks = True)` wires this over the gate suite it assembles.

`bazel run //<pkg>:<name>` installs: it writes `<hooks_dir>/pre-commit` into the working
tree and points git at it via `core.hooksPath`. The devcontainer/bootstrap calls it once.

Implemented as a tiny executable rule (not sh_binary) so consumers don't need rules_shell,
and the install script EMBEDS the hook inline (heredoc) so there are no runfiles to resolve.

<a id="git_hooks"></a>

## git_hooks

<pre>
load("@rules_ci//hooks:defs.bzl", "git_hooks")

git_hooks(<a href="#git_hooks-name">name</a>, <a href="#git_hooks-gates">gates</a>, <a href="#git_hooks-hooks_dir">hooks_dir</a>)
</pre>

`bazel run` installs a pre-commit hook (runs `gates`, hard-block) + sets core.hooksPath.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="git_hooks-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="git_hooks-gates"></a>gates |  The bazel test target the hook runs (the `ci_gates` suite label, as text).   | String | required |  |
| <a id="git_hooks-hooks_dir"></a>hooks_dir |  Working-tree dir for the hook; core.hooksPath is pointed here.   | String | optional |  `".githooks"`  |

## Versioning + the Rust translator

Automated, surface-driven versioning (proto DTOs in `proto/fastverk/release/v1/`, the `version/`
tools, the escalation seam) is documented in [`docs/VERSIONING.md`](docs/VERSIONING.md). The Rust
CI-IR translator (`//translator`, dev-scoped) and its proof strategy are in
[`docs/DESIGN.md`](docs/DESIGN.md).
