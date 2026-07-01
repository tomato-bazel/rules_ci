"""fastverk_project — the generic per-repo convention macro (the fastverk layer).

Composes the project-level wiring a repo needs — CI, README/badges, git hooks,
versioning — from the underlying rulesets (rules_gitlab, rules_readme), driven by the
products the `//release:release_artifacts` aspect discovers in the build graph. The upper
layers wrap this: aion/rules' `aion_framework_library` / `aion_framework_project`, and
studio's `aion_app(features = [...])`.

Milestone 1: the `.gitlab-ci.yml` generator — emit + schema-validate + drift-gate a thin
pipeline from a caller-supplied `include:` + CI variables.

Milestone 3 (this revision): `features` + the release-products gate. A *feature* is a
named bundle of (CI lane include(s), CI variables, expected shippable products). The
upper layers own the feature CATALOG — studio's `aion_app(features = ["web", "tui"])`
resolves names → the resolved `features` dict this macro consumes — so the generic layer
stays catalog-agnostic. When the repo points `products` at its top-level product targets,
the macro materializes the discovered-products manifest and, against the declared set, a
declared-vs-discovered DRIFT GATE (`products_drift_test`) — the connection between the
features a repo turns on and the artifacts it's allowed to ship.

Badges, git hooks, and the versioning workflow land in subsequent milestones.
"""

load("@rules_gitlab//gitlab:defs.bzl", "gitlab_ci")
load("@rules_readme//readme:defs.bzl", "markdown_fragment")
load("//hooks:defs.bzl", "git_hooks")
load("//release:defs.bzl", "products_drift_test", "release_manifest")

# GitLab serves NATIVE status badges per project — no shields.io / codecov needed. The
# coverage badge reads the value GitLab scraped from the job's `coverage:` regex (the M2
# coverage lane), and the pipeline badge reflects the latest default-branch run.
def _badge_markdown(host, repo, branch):
    pipelines = "https://{host}/{repo}/-/pipelines".format(host = host, repo = repo)
    pipeline_svg = "https://{host}/{repo}/badges/{branch}/pipeline.svg".format(host = host, repo = repo, branch = branch)
    coverage_svg = "https://{host}/{repo}/badges/{branch}/coverage.svg".format(host = host, repo = repo, branch = branch)
    return ("[![pipeline]({psvg})]({pipes}) ".format(psvg = pipeline_svg, pipes = pipelines) +
            "[![coverage]({csvg})]({pipes})".format(csvg = coverage_svg, pipes = pipelines))

def fastverk_project(
        name = "project",
        repo = None,
        ci_include = [],
        ci_variables = {},
        ci_stages = [],
        ci_jobs = {},
        ci_extra = {},
        features = {},
        products = [],
        expected_products = [],
        gate_tests = [],
        hooks = False,
        hooks_dir = ".githooks",
        badges = False,
        host = "gitlab.savvifi.com",
        badge_branch = "main",
        write_to = ".gitlab-ci.yml",
        validate = True,
        visibility = None):
    """Generic project-level wiring: the CI generator + the release-products gate.

    Generates `<write_to>` and the drift/validation gates:

        bazel run  //:<name>.ci.update           # (re)generate the pipeline into the tree
        bazel test //:<name>.ci.update_test      # CI-drift gate (CI + the pre-commit hook)
        bazel build //:<name>.ci_validate        # schema gate

    And, when `products` is set, the release-products seam:

        bazel build //:<name>.products           # the discovered-products JSON manifest
        bazel test  //:<name>.products_drift_test # declared-vs-discovered drift gate

    Plus the unified gate suite (and, with `hooks = True`, the installer):

        bazel test //:<name>.ci_gates            # every drift/validation gate (CI + the hook)
        bazel run  //:<name>.hooks_install       # install the pre-commit hook (core.hooksPath)

    Args:
      name: base name; generates `<name>.ci`, `<name>.ci.update`, `<name>.ci_validate`,
        and (when `products` is set) `<name>.products` + `<name>.products_drift_test`.
      repo: OWNER/REPO on the git host (e.g. "aion/db"). Used for the README badges.
      ci_include: base GitLab `include:` entries (list of dicts) — shared lane(s) to pull in.
      ci_variables: base global CI/CD variables (dict).
      ci_stages: explicit pipeline stages (usually empty — the included lane owns them).
      ci_jobs: repo-local jobs (usually empty — jobs live in the shared lane).
      ci_extra: escape-hatch raw top-level keys merged into the generated pipeline.
      features: resolved feature bundles, `{name: {"include": [...], "variables": {...},
        "jobs": {...}, "expects": [{"kind","name"}, ...]}}`. Enabling a feature = its
        presence here; its `include`/`variables`/`jobs` union onto the base CI, and its
        `expects` join the declared product set for the drift gate. The upper layers turn
        `["web", "tui"]` into this dict; the generic layer never hardcodes which features
        exist. A sibling product ruleset can EXPORT a helper returning such a bundle (e.g.
        rules_tap's affected-test lane as inline `jobs`) — so fastverk_project composes it
        WITHOUT a hard dep on that ruleset. Example:

            load("@rules_tap//ci:defs.bzl", "tap_ci_feature")
            fastverk_project(name = "project", repo = "aion/db",
                             features = {"tap": tap_ci_feature()})  # adds the affected-test lane
      products: top-level product targets (labels) to run the `release_artifacts` aspect
        over — the inputs to the manifest + drift gate. Empty ⇒ no release-products targets.
      expected_products: products the repo declares it ships, as `[{"kind","name"}, ...]`
        (merged with every enabled feature's `expects`). Drives the drift gate; empty (and
        no feature expects) ⇒ the manifest is still emitted but no gate is generated.
      gate_tests: EXTRA gate test labels to fold into `<name>.ci_gates` (e.g. the repo's
        `:readme.write_test`, a lockfile drift test, a manifest `objects.json` gate). The
        macro's own gates (`.ci.update_test`, `.products_drift_test`) are added automatically.
      hooks: also generate `<name>.hooks_install` — `bazel run` it to install a pre-commit
        hook that runs `<name>.ci_gates` (hard block, no auto-fix) + sets `core.hooksPath`.
        Local/CI parity: the hook runs the SAME suite as CI. Default off.
      hooks_dir: working-tree dir the pre-commit hook is installed into (default ".githooks").
      badges: emit a `<name>.badges` rules_readme `markdown_fragment` (slot "badges") with
        the GitLab-native pipeline + coverage badges for `repo`. The repo's README template
        composes it: `<!-- FRAGMENTS:badges -->` + `readme(fragments=[":<name>.badges"])`.
        Requires `repo`. Default off (opt-in until a repo wires the slot).
      host: the git host for the badge URLs (default "gitlab.savvifi.com").
      badge_branch: the branch the badges reflect (default "main").
      write_to: source-relative output path (default `.gitlab-ci.yml`).
      validate: schema-validate the generated file (default True).
      visibility: target visibility for the generated targets.
    """

    # Resolve features onto the base CI config. A feature contributes lane include(s),
    # CI variables, and expected products; iterate in a stable order so the generated
    # pipeline is deterministic regardless of dict insertion order.
    include = list(ci_include)
    variables = dict(ci_variables)
    jobs = dict(ci_jobs)
    declared = list(expected_products)
    for fname in sorted(features.keys()):
        spec = features[fname]
        for inc in spec.get("include", []):
            include.append(inc)
        for k, v in spec.get("variables", {}).items():
            variables[k] = v
        for jk, jv in spec.get("jobs", {}).items():
            jobs[jk] = jv
        for exp in spec.get("expects", []):
            declared.append(exp)

    gitlab_ci(
        name = name + ".ci",
        include = include if include else None,
        variables = variables,
        stages = ci_stages,
        jobs = jobs,
        extra = ci_extra,
        write_to = write_to,
        validate = validate,
        visibility = visibility,
    )

    # The release-products seam: a manifest of what the build graph produces, plus a
    # gate asserting that matches what the repo (and its enabled features) declared.
    gates = [name + ".ci.update_test"]  # gitlab_ci's drift gate (always generated)
    if products:
        release_manifest(
            name = name + ".products",
            deps = products,
            visibility = visibility,
        )
        if declared:
            products_drift_test(
                name = name + ".products_drift_test",
                deps = products,
                expected = [p["kind"] + ":" + p["name"] for p in declared],
                visibility = visibility,
            )
            gates.append(name + ".products_drift_test")

    # The CI-gate suite: the single label both CI and the pre-commit hook run. Aggregates
    # the macro's own drift/validation gates plus any `gate_tests` the repo wires in (its
    # README drift test, lockfile gate, manifest gate, …).
    native.test_suite(
        name = name + ".ci_gates",
        tests = [":" + g for g in gates] + gate_tests,
        visibility = visibility,
    )

    # Git hooks: `bazel run <name>.hooks_install` writes a pre-commit hook that runs the
    # same ci_gates suite (hard block) + sets core.hooksPath. Local/CI parity.
    if hooks:
        gates_label = "//" + native.package_name() + ":" + name + ".ci_gates"
        git_hooks(
            name = name + ".hooks_install",
            gates = gates_label,
            hooks_dir = hooks_dir,
            visibility = visibility,
        )

    # The README badge fragment: GitLab-native pipeline + coverage badges, composed into
    # the repo's README via rules_readme's `badges` slot. A fragment (not a whole README)
    # so the repo keeps ownership of its template + prose.
    if badges:
        if not repo:
            fail("fastverk_project(badges = True) requires `repo` (OWNER/REPO) for the badge URLs.")
        markdown_fragment(
            name = name + ".badges",
            content = _badge_markdown(host, repo, badge_branch),
            slot = "badges",
            visibility = visibility,
        )
