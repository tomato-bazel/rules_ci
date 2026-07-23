"""Runtime macros for the CI-as-Bazel-targets surface: `ci_job` / `ci_publish` / `ci_pipeline`.

This is the vendor-neutral CI *runtime* that the IR's `bazel-emit` targets (and hand-authored
pipelines) expand into — the concrete realization of the shape sketched in
[`docs/DESIGN.md`](../../docs/DESIGN.md) ("Bazel-emit"). A pipeline is a set of ordinary Bazel
targets:

  * hermetic **test** jobs run under `bazel test` (a `sh_test`, or an alias of an existing
    test/`test_suite` target for Bazel-native repos),
  * side-effecting **publish** jobs run under `bazel run` (a `sh_binary`; credentials come from
    the runner's environment, never the sandbox),
  * and the pipeline emits a machine-readable `<name>.pipeline.json` — the `Build.publish[]`
    contract the fastverk build-runner reads to drive artifact publishing on a push/tag.

The point of the runtime is that a repo can express its whole CI as `ci_*` targets and delete its
`.gitlab-ci.yml` (readiness criterion C2): `bazel test //ci:<pipeline>` is the test gate, and the
build-runner replays the publish jobs from the manifest.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Publish kinds the runtime + the build-runner both understand. Keep in sync with the
# build-runner's `Build.publish[].kind` dispatcher (owned by opus-deploy).
PUBLISH_KINDS = ["static_cdn", "site", "oci", "github_release", "npm"]

def ci_job(
        name,
        script = None,
        test = None,
        stage = "test",
        needs = [],
        image = "",
        size = "medium",
        tags = [],
        data = [],
        vacuity_gate = True,
        **kwargs):
    """A single pipeline job. Returns a struct consumed by `ci_pipeline(jobs = [...])`.

    Exactly one of `script` or `test` must be set. `script` (shell lines) is materialized as
    `<name>.sh` and run as an `sh_test`; `test` aliases an existing test / `test_suite` this job
    *is* (for Bazel-native repos whose jobs are already test targets, e.g. `//ci:pr_gates`).

    Args:
      name: job (and target) name.
      script: list of shell lines to run as an `sh_test`. Mutually exclusive with `test`.
      test: label of an existing test/`test_suite` this job aliases. Mutually exclusive with `script`.
      stage: pipeline stage label, carried as a tag for introspection + the IR round-trip.
      needs: predecessor job labels; attached as `data` (their outputs land in the job's runfiles)
        — the structural approximation of a GitLab `needs:` edge, per docs/DESIGN.md.
      image: optional container image the job runs in, carried as a tag.
      size: `sh_test` size (script jobs only).
      tags: extra tags added to the job.
      data: extra runtime data for script jobs.
      vacuity_gate: for `test =` jobs, also emit `<name>.not_vacuous_test` — a gate asserting
        the job actually expands to at least one test. Set False only for a job deliberately
        allowed to be empty. Ignored by `script =` jobs, which cannot be vacuous.
      **kwargs: forwarded to the underlying `sh_test`.

    Returns:
      A struct `{kind, name, label, stage, needs}` for `ci_pipeline`.
    """
    if (script == None) == (test == None):
        fail("ci_job(%s): set exactly one of `script` or `test`" % name)

    job_tags = tags + ["ci-job", "ci-stage=" + stage] + (["ci-image=" + image] if image else [])

    if script != None:
        write_file(
            name = "%s.script" % name,
            out = "%s.sh" % name,
            content = ["#!/usr/bin/env bash", "set -euo pipefail", ""] + script,
            is_executable = True,
        )
        sh_test(
            name = name,
            srcs = ["%s.sh" % name],
            data = data + needs,
            size = size,
            tags = job_tags,
            **kwargs
        )
    else:
        # Alias an existing test/test_suite as a named job so it can be a pipeline member.
        #
        # TWO suites, and the inner one is load-bearing. A `test_suite`'s `tags` FILTER
        # its direct members: a test that does not itself carry every positive tag is
        # dropped from the suite. `job_tags` always contains `ci-job` and `ci-stage=…`,
        # which no ordinary test carries — so `test_suite(tests = [test], tags = job_tags)`
        # silently resolved to an EMPTY suite, and `bazel test //ci:<job>` passed having
        # run nothing.
        #
        # That is the worst failure mode a CI gate has: it does not break, it reports
        # green while verifying nothing, and it does so for exactly the security-shaped
        # targets people name explicitly as jobs.
        #
        # Nested `test_suite`s are EXPANDED rather than filtered, so routing the aliased
        # target through an untagged inner suite restores the members while the outer
        # suite keeps the tags for introspection / the IR round-trip. This is also why
        # the bug hid for so long: a job aliasing a target that was ITSELF a test_suite
        # (e.g. `test = "//proto:aip_lint"`) worked correctly, so the breakage looked
        # target-specific rather than systematic.
        native.test_suite(name = "%s.tests" % name, tests = [test])
        native.test_suite(name = name, tests = ["%s.tests" % name], tags = job_tags)

        # And a gate that the job is not EMPTY.
        #
        # The fix above removes the cause we know about, but not the failure mode: a
        # `test_suite` with no matching members resolves to nothing rather than
        # erroring, so aliasing an empty suite (or one whose own tag filter matched
        # nothing) still yields a job that passes having run zero tests. Vacuity is
        # invisible in `bazel test` output and identical to success in the pipeline
        # manifest, which records job labels rather than the tests behind them — so
        # nothing else in this ruleset can notice it.
        #
        # Per-job rather than per-pipeline on purpose: `tests(<pipeline>)` is
        # non-empty as long as ANY job has tests, so a whole-pipeline check cannot
        # localize (or even detect) one hollow job among several.
        if vacuity_gate:
            native.genquery(
                name = "%s.query" % name,
                expression = "tests(%s)" % native.package_relative_label(name),
                scope = [":" + name],
            )
            sh_test(
                name = "%s.not_vacuous_test" % name,
                srcs = ["@rules_ci//ci:not_vacuous_test.sh"],
                data = [":%s.query" % name],
                env = {
                    "TESTS": "$(rootpath :%s.query)" % name,
                    "JOB": name,
                },
                size = "small",
                tags = ["ci-vacuity-gate"],
            )

    return struct(
        kind = "test",
        name = name,
        label = ":" + name,
        stage = stage,
        needs = needs,
    )

def ci_publish(
        name,
        artifact,
        kind,
        destination = "",
        stage = "publish",
        needs = [],
        repo = "",
        tag = "",
        asset = "",
        tags = [],
        **kwargs):
    """A side-effecting publish job → an `sh_binary` you `bazel run` (creds from the runner env).

    Also contributes a structured entry to the enclosing `ci_pipeline`'s `pipeline.json` — the
    `Build.publish[]` the build-runner replays. The generated binary shells out to the shared
    `publish_runner.sh` dispatcher; the *actual* upload requires the runner's credentials, so a
    local `bazel run` without them is a safe no-op that logs what it would do.

    Args:
      name: job (and target) name.
      artifact: label of the single built file to publish (e.g. an olean tarball, a site tarball,
        an `npm pack` tarball).
      kind: one of `PUBLISH_KINDS` — `static_cdn` (immutable content-addressed upload under
        `destination`), `site` (extract + sync to `destination`), `oci` (push to the `destination`
        registry ref), `github_release` (upload to `repo`'s release for `tag`), or `npm` (publish
        an npm tarball to the `destination` registry).
      destination: `s3://…` prefix / CDN origin / registry ref (static_cdn|site|oci) or the npm
        registry URL (npm), e.g.
        `https://gitlab.example.com/api/v4/projects/<id>/packages/npm/`.
      stage: pipeline stage label, carried as a tag.
      needs: predecessor job labels (recorded in the manifest entry).
      repo: `owner/name` GitHub repo (github_release only).
      tag: release tag (github_release only).
      asset: published asset name (github_release only; defaults to the artifact basename).
      tags: extra tags added to the job.
      **kwargs: forwarded to the underlying `sh_binary`.

    Returns:
      A struct `{kind, name, label, stage, needs, target, destination, repo, tag, asset}` for
      `ci_pipeline`.
    """
    if kind not in PUBLISH_KINDS:
        fail("ci_publish(%s): kind %r not in %s" % (name, kind, PUBLISH_KINDS))

    sh_binary(
        name = name,
        srcs = ["@rules_ci//ci:publish_runner.sh"],
        data = [artifact],
        # `--flag=value` single tokens so empty values stay attached (a dropped empty
        # arg would desync a paired `--flag value` parser).
        args = [
            "--kind=" + kind,
            "--artifact=$(rootpath %s)" % artifact,
            "--destination=" + destination,
            "--repo=" + repo,
            "--tag=" + tag,
            "--asset=" + asset,
        ],
        tags = tags + ["ci-job", "ci-publish", "ci-stage=" + stage, "ci-publish-kind=" + kind],
        **kwargs
    )

    return struct(
        kind = kind,
        name = name,
        label = ":" + name,
        stage = stage,
        needs = needs,
        target = artifact,
        destination = destination,
        repo = repo,
        tag = tag,
        asset = asset,
    )

def ci_pipeline(name, jobs = [], visibility = None):
    """Compose `ci_job`/`ci_publish` results into a runnable pipeline.

    Test jobs (`kind == "test"`) become a `test_suite(name)` so `bazel test //ci:<name>` is the
    gate; publish jobs are recorded in `<name>.pipeline.json` (the `Build.publish[]` contract).

    Args:
      name: pipeline (and `test_suite`) name.
      jobs: list of the structs returned by `ci_job(...)` / `ci_publish(...)`.
      visibility: visibility for the generated `test_suite` + manifest.
    """
    test_labels = [j.label for j in jobs if j.kind == "test"]
    publishes = [j for j in jobs if j.kind != "test"]

    native.test_suite(
        name = name,
        tests = test_labels,
        visibility = visibility,
    )

    _ci_manifest(
        name = "%s.manifest" % name,
        pipeline_name = name,
        test_targets_json = json.encode([str(lbl) for lbl in test_labels]),
        publishes_json = json.encode([
            {
                "name": p.name,
                "kind": p.kind,
                "stage": p.stage,
                "target": str(p.target),
                "destination": p.destination,
                "repo": p.repo,
                "tag": p.tag,
                "asset": p.asset,
                "needs": [str(n) for n in p.needs],
            }
            for p in publishes
        ]),
        visibility = visibility,
    )

def _ci_manifest_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.pipeline_name + ".pipeline.json")
    manifest = {
        "pipeline": ctx.attr.pipeline_name,
        "test_targets": json.decode(ctx.attr.test_targets_json),
        "publish": json.decode(ctx.attr.publishes_json),
    }
    ctx.actions.write(out, json.encode_indent(manifest, indent = "  ") + "\n")
    return [DefaultInfo(files = depset([out]))]

_ci_manifest = rule(
    implementation = _ci_manifest_impl,
    doc = "Emit `<pipeline>.pipeline.json` — the Build.publish[] contract the build-runner reads.",
    attrs = {
        "pipeline_name": attr.string(mandatory = True),
        "test_targets_json": attr.string(mandatory = True),
        "publishes_json": attr.string(mandatory = True),
    },
)
