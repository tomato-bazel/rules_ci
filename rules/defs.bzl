"""User-facing Bazel rules for rules_ci_ir.

v0.0.1 ships one working rule (`ci_yaml_aggregate`, backed by the
Rust aggregator binary) and the public signatures of the others
as stubs that `fail(...)`. The stubs lock the API surface so
consumers can start writing BUILDs against them now; the rule
bodies fill in per the roadmap in [`docs/DESIGN.md`](../docs/DESIGN.md).
"""

def _ci_yaml_aggregate_impl(ctx):
    json_out = ctx.actions.declare_file(ctx.label.name + ".fleet.json")
    md_out = ctx.actions.declare_file(ctx.label.name + ".fleet.md")

    args = ctx.actions.args()
    args.add("--json-out", json_out.path)
    args.add("--report-out", md_out.path)
    inputs = []
    for member_name, target in ctx.attr.members.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("ci_yaml_aggregate: member {} -> {} produced {} files (expected 1)".format(
                member_name,
                target.label,
                len(files),
            ))
        src = files[0]
        inputs.append(src)
        args.add("--member", "{}={}".format(member_name, src.path))

    ctx.actions.run(
        executable = ctx.executable._aggregator,
        arguments = [args],
        inputs = inputs,
        outputs = [json_out, md_out],
        mnemonic = "CiYamlAggregate",
        progress_message = "Aggregating CI YAML across %d members (%s)" % (
            len(ctx.attr.members),
            ctx.label,
        ),
    )
    return [DefaultInfo(files = depset([json_out, md_out]))]

ci_yaml_aggregate = rule(
    implementation = _ci_yaml_aggregate_impl,
    doc = "Aggregate N members' CI YAML into a normalized IR + Markdown similarity report. " +
          "Drop-in Rust replacement for savvi's Python ci_analysis aggregator.",
    attrs = {
        "members": attr.string_keyed_label_dict(
            mandatory = True,
            allow_empty = False,
            allow_files = [".yml", ".yaml"],
            doc = "Map of human-readable member name → label of the CI YAML.",
        ),
        "_aggregator": attr.label(
            default = "//translator:ci_aggregator",
            executable = True,
            cfg = "exec",
        ),
    },
)

def _stub(ctx):
    fail(
        "{}: not implemented in v0.0.1 — see docs/DESIGN.md for the roadmap.".format(ctx.label),
    )

ci_yaml_translate = rule(
    implementation = _stub,
    doc = "Translate a CI YAML between formats. v0.0.1 stub — landing in v0.3.0 per the roadmap.",
    attrs = {
        "src": attr.label(allow_single_file = [".yml", ".yaml"]),
        "from_format": attr.string(values = ["gitlab", "github"], default = "gitlab"),
        "to_format": attr.string(values = ["gitlab", "github", "bazel"], default = "github"),
    },
)

ci_yaml_diff = rule(
    implementation = _stub,
    doc = "Structural diff of two CI YAMLs at the IR level. v0.0.1 stub — landing in v0.4.0+ per the roadmap.",
    attrs = {
        "a": attr.label(allow_single_file = [".yml", ".yaml"]),
        "b": attr.label(allow_single_file = [".yml", ".yaml"]),
    },
)
