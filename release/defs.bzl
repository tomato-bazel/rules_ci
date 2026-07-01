"""release_artifacts — make the build graph's "versioned products" first-class.

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
"""

ReleaseArtifactInfo = provider(
    doc = "Normalized view of one shippable, versioned product discovered in the graph.",
    fields = {
        "kind": "Product kind: npm | oci | helm | site | module_bundle.",
        "name": "The product's published name (npm package name, image repo, chart name).",
        "label": "The Bazel label that produces it (string).",
        "version_source": "Where the version is read (e.g. the package.json File), or None.",
        "surface": "Tuple of Files describing the public surface for versioning (npm: the .d.ts* closure); () if none.",
    },
)

ReleaseArtifactsInfo = provider(
    doc = "Aggregate of every ReleaseArtifactInfo reachable from a target.",
    fields = {"products": "depset of ReleaseArtifactInfo."},
)

# Underlying rule kind -> product kind. Note: the user-facing names (npm_package,
# oci_image, …) are MACROS that expand to private rules — detection keys off the real
# rule kind (`_npm_package` for aspect_rules_js's npm_package macro). These private names
# are version-sensitive across the underlying rulesets; pinned here + covered by the
# release_manifest example so a rename surfaces as a test failure.
_KIND_BY_RULE = {
    "_npm_package": "npm",  # aspect_rules_js npm_package macro -> _npm_package rule
    "npm_package": "npm",   # fallback if a future version exposes it as a rule
    "oci_image": "oci",
    "oci_push": "oci",
    "helm_chart": "helm",
    # the aion module-bundle rule kind is wired when that bundle product lands.
}

# attrs the aspect propagates along to find products in the dependency closure.
_PROPAGATE = ["deps", "srcs", "data"]

# product-kind string -> the fastverk.release.v1.Product.Kind proto ENUM NAME (proto3-JSON
# encodes enums by name). The release_manifest emits the ReleaseManifest message as proto3 JSON.
_KIND_PROTO_ENUM = {
    "npm": "NPM",
    "oci": "OCI",
    "helm": "HELM",
    "site": "SITE",
    "module_bundle": "MODULE_BUNDLE",
    "binary": "BINARY",
}

def _npm_package_json(ctx):
    """Find the package.json File among an npm_package's srcs (the version source)."""
    for src in getattr(ctx.rule.attr, "srcs", None) or []:
        if type(src) != "Target":
            continue
        for f in src.files.to_list():
            if f.basename == "package.json":
                return f
    return None

# Suffixes of TypeScript declaration files — the npm public surface for versioning.
_DTS_SUFFIXES = (".d.ts", ".d.mts", ".d.cts")

def _surface_dts(ctx):
    """Convention-based public-surface capture for an npm product: every `.d.ts*` file
    among the package's srcs (whether hand-written or emitted by a `ts_project`).

    Deliberately convention-based (scan by extension) rather than importing rules_ts's
    `DeclarationInfo` — same robustness rationale as the kind-based product detection: no
    dependency on a version-sensitive external provider symbol, and it works for a raw
    `npm_package` too. The versioning workflow can upgrade this to the type-checked
    `DeclarationInfo` closure when it needs the exact emitted-types set; until then this is
    a sufficient diffable descriptor of the published types.
    """
    dts = []
    for src in getattr(ctx.rule.attr, "srcs", None) or []:
        if type(src) != "Target":
            continue
        for f in src.files.to_list():
            for suf in _DTS_SUFFIXES:
                if f.path.endswith(suf):
                    dts.append(f)
                    break

    # Return a TUPLE, not a list: ReleaseArtifactInfo instances are stored in a depset,
    # whose elements must be immutable — a provider with a list field is mutable and is
    # rejected ("depset elements must not be mutable values").
    return tuple(dts)

def _release_artifacts_aspect_impl(target, ctx):
    direct = []
    product_kind = _KIND_BY_RULE.get(ctx.rule.kind)
    if product_kind:
        # npm: the published name is the `package` attr (savvi_ts_package passes
        # `package_name` through to it); the version lives in package.json (publish.mjs
        # reads it), so version_source = that File. The public-surface descriptor
        # (rules_ts DeclarationInfo .d.ts closure) is wired in a later milestone.
        name = getattr(ctx.rule.attr, "package", None) or ctx.label.name
        direct.append(ReleaseArtifactInfo(
            kind = product_kind,
            name = name,
            label = str(ctx.label),
            version_source = _npm_package_json(ctx) if product_kind == "npm" else None,
            surface = _surface_dts(ctx) if product_kind == "npm" else (),
        ))

    transitive = []
    for attr_name in _PROPAGATE:
        for dep in getattr(ctx.rule.attr, attr_name, None) or []:
            if type(dep) == "Target" and ReleaseArtifactsInfo in dep:
                transitive.append(dep[ReleaseArtifactsInfo].products)

    return [ReleaseArtifactsInfo(products = depset(direct = direct, transitive = transitive))]

release_artifacts = aspect(
    implementation = _release_artifacts_aspect_impl,
    attr_aspects = _PROPAGATE,
    doc = "Walk a target's graph and collect its shippable products as ReleaseArtifactInfo.",
)

# ─── release_manifest: materialize the discovered products as the ReleaseManifest proto ──
#
# The seam the versioning workflow reads: apply `release_artifacts` to the repo's top-level
# target(s) and emit the fastverk.release.v1.ReleaseManifest message (per "DTOs are protos").
# Emitted as proto3-JSON — the canonical JSON serialization of the proto (enum names + camelCase
# fields) — NOT ad-hoc JSON. Done in Starlark (json.encode), so NO protoc/protobuf dep reaches
# consumers (the proto stays dev-scoped); the version/ tools load it via protobufjs
# (ReleaseManifest.fromObject accepts proto3-JSON). Also the test harness for the aspect.

def _release_manifest_impl(ctx):
    products = []
    for dep in ctx.attr.deps:
        if ReleaseArtifactsInfo in dep:
            for p in dep[ReleaseArtifactsInfo].products.to_list():
                products.append(struct(
                    kind = _KIND_PROTO_ENUM.get(p.kind, "KIND_UNSPECIFIED"),
                    name = p.name,
                    label = p.label,
                    versionSource = p.version_source.path if p.version_source else "",
                    surfacePaths = [f.path for f in p.surface] if p.surface else [],
                ))
    # The ReleaseManifest wrapper message: { "products": [ Product, ... ] }.
    manifest = struct(products = products)
    out = ctx.actions.declare_file(ctx.label.name + ".products.json")
    ctx.actions.write(out, json.encode_indent(manifest, prefix = "", indent = "  "))
    return [DefaultInfo(files = depset([out]))]

release_manifest = rule(
    implementation = _release_manifest_impl,
    doc = "Emit the fastverk.release.v1.ReleaseManifest (proto3-JSON) of every product under `deps`.",
    attrs = {
        "deps": attr.label_list(
            aspects = [release_artifacts],
            doc = "Top-level targets to discover products under.",
        ),
    },
)

# ─── products_drift_test: declared-vs-discovered release-products gate ─────────
#
# A repo DECLARES the products it intends to ship (via `fastverk_project`'s
# features/expected_products — the macro normalizes them to "kind:name" strings).
# This test DISCOVERS what the build graph actually produces (the `release_artifacts`
# aspect over the same top-level targets) and fails on ANY mismatch in either
# direction:
#   • DECLARED but NOT BUILT  → a product stopped being produced (or was misnamed).
#   • BUILT but NOT DECLARED  → a NEW shippable product slipped in unannounced (it
#     would otherwise publish + version with no one having declared it).
# Both are "drift". The comparison is resolved at analysis time and baked into a
# trivial pass/fail script, so the gate shows up as a normal red/green test in the
# `bazel test //...` lane (and the pre-commit hook).

def _products_drift_test_impl(ctx):
    discovered = {}
    for dep in ctx.attr.deps:
        if ReleaseArtifactsInfo in dep:
            for p in dep[ReleaseArtifactsInfo].products.to_list():
                discovered[p.kind + ":" + p.name] = True
    discovered_keys = sorted(discovered.keys())

    declared = {e: True for e in ctx.attr.expected}
    declared_keys = sorted(declared.keys())

    missing = [k for k in declared_keys if k not in discovered]
    extra = [k for k in discovered_keys if k not in declared]

    lines = [
        "#!/usr/bin/env bash",
        "# GENERATED by products_drift_test — declared-vs-discovered release-products gate.",
        "set -euo pipefail",
    ]
    if missing or extra:
        lines.append("echo 'release-products drift detected:'")
        for k in missing:
            lines.append("echo '  - DECLARED but NOT BUILT: %s'" % k)
        for k in extra:
            lines.append("echo '  + BUILT but NOT DECLARED: %s'" % k)
        lines.append("echo")
        lines.append("echo 'Reconcile the fastverk_project(features=...) / expected_products declaration with the build graph.'")
        lines.append("exit 1")
    else:
        lines.append("echo 'release-products drift gate OK: %d declared == %d discovered'" % (len(declared_keys), len(discovered_keys)))
        for k in declared_keys:
            lines.append("echo '  = %s'" % k)
        lines.append("exit 0")

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "\n".join(lines) + "\n",
        is_executable = True,
    )
    return [DefaultInfo(executable = script)]

products_drift_test = rule(
    implementation = _products_drift_test_impl,
    test = True,
    doc = "Fail if the products discovered under `deps` differ from the declared `expected` set.",
    attrs = {
        "deps": attr.label_list(
            aspects = [release_artifacts],
            doc = "Top-level targets whose discovered products are checked against `expected`.",
        ),
        "expected": attr.string_list(
            doc = "Declared products as normalized \"kind:name\" entries (e.g. \"npm:@aion/foo\").",
        ),
    },
)
