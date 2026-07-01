"""git_hooks — install a pre-commit hook that runs the SAME gates as CI.

The local/CI parity rule: a developer's pre-commit runs exactly the `ci_gates` test_suite
that CI runs — so a commit that would fail the pipeline's drift/validation gates (stale
generated `.gitlab-ci.yml`, README, products manifest, lockfiles, …) is blocked locally
FIRST. Hard block, NO auto-fix: the dev runs the named `.update`/`.write` target and
re-commits. `fastverk_project(hooks = True)` wires this over the gate suite it assembles.

`bazel run //<pkg>:<name>` installs: it writes `<hooks_dir>/pre-commit` into the working
tree and points git at it via `core.hooksPath`. The devcontainer/bootstrap calls it once.

Implemented as a tiny executable rule (not sh_binary) so consumers don't need rules_shell,
and the install script EMBEDS the hook inline (heredoc) so there are no runfiles to resolve.
"""

def _hook_lines(gates):
    """The pre-commit hook body — runs `bazel test <gates>`, hard-blocks on failure."""
    return [
        "#!/usr/bin/env bash",
        "# @generated fastverk pre-commit hook — runs the SAME gates as CI (local/CI parity).",
        "# Hard block, no auto-fix: on failure run the offending `.update`/`.write` target and re-commit.",
        "set -euo pipefail",
        "echo '[fastverk pre-commit] running CI gates: " + gates + "'",
        "if ! bazel test " + gates + "; then",
        "  echo '' >&2",
        "  echo '[fastverk pre-commit] BLOCKED — CI gates failed.' >&2",
        "  echo '  A generated artifact is stale or invalid. Regenerate it (e.g.' >&2",
        "  echo '  `bazel run //:<target>.update` / `.write`), stage, and re-commit.' >&2",
        "  echo '  (No auto-fix by design — the diff stays yours to review.)' >&2",
        "  exit 1",
        "fi",
    ]

def _install_content(gates, hooks_dir):
    """The `bazel run`-able installer: materializes the hook + sets core.hooksPath."""
    lines = [
        "#!/usr/bin/env bash",
        "# @generated fastverk git-hooks installer.",
        "set -euo pipefail",
        ": \"${BUILD_WORKSPACE_DIRECTORY:?must be run via 'bazel run' (need BUILD_WORKSPACE_DIRECTORY)}\"",
        "HOOKS_DIR=\"$BUILD_WORKSPACE_DIRECTORY/" + hooks_dir + "\"",
        "mkdir -p \"$HOOKS_DIR\"",
        "cat > \"$HOOKS_DIR/pre-commit\" <<'FASTVERK_HOOK_EOF'",
    ] + _hook_lines(gates) + [
        "FASTVERK_HOOK_EOF",
        "chmod +x \"$HOOKS_DIR/pre-commit\"",
        "git -C \"$BUILD_WORKSPACE_DIRECTORY\" config core.hooksPath " + hooks_dir,
        "echo \"[fastverk] installed pre-commit -> " + hooks_dir + "/pre-commit (core.hooksPath set)\"",
    ]
    return "\n".join(lines) + "\n"

def _git_hooks_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".install.sh")
    ctx.actions.write(
        output = script,
        content = _install_content(ctx.attr.gates, ctx.attr.hooks_dir),
        is_executable = True,
    )
    return [DefaultInfo(executable = script)]

git_hooks = rule(
    implementation = _git_hooks_impl,
    executable = True,
    doc = "`bazel run` installs a pre-commit hook (runs `gates`, hard-block) + sets core.hooksPath.",
    attrs = {
        "gates": attr.string(
            mandatory = True,
            doc = "The bazel test target the hook runs (the `ci_gates` suite label, as text).",
        ),
        "hooks_dir": attr.string(
            default = ".githooks",
            doc = "Working-tree dir for the hook; core.hooksPath is pointed here.",
        ),
    },
)
