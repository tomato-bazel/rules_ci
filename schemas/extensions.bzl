"""Module extension: pin upstream CI/Workflow JSON Schemas.

Two schemas, fetched from their canonical upstream sources and
content-sha-pinned for reproducibility. Refresh procedure in
[`docs/DESIGN.md`](../docs/DESIGN.md).
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

# Canonical GitLab CI JSON Schema — the file GitLab's web editor
# ships. Already pinned the same way in fastverk/rules_gitlab; we
# duplicate the pin here (rather than depend on rules_gitlab) so
# rules_ci_ir stays independent of the rules_gitlab release
# cadence.
_GITLAB_CI_URL = "https://gitlab.com/gitlab-org/gitlab-foss/-/raw/master/app/assets/javascripts/editor/schema/ci.json"
_GITLAB_CI_SHA256 = "1e4a59db14999771c45e4b0ab646d663e95607698aa8940f7afed82a9a0d5054"

# Curated GitHub Actions workflow schema (SchemaStore's mirror —
# more stable than GitHub's own internal one, used by every major
# JSON Schema-driven YAML language server).
_GITHUB_WORKFLOW_URL = "https://json.schemastore.org/github-workflow.json"
_GITHUB_WORKFLOW_SHA256 = "30e8f011e5337e90459776a2e01d8fd17ae199904b8ef12a6fd715edf599d79b"

def _ci_schemas_impl(_mctx):
    http_file(
        name = "gitlab_ci_schema",
        urls = [_GITLAB_CI_URL],
        sha256 = _GITLAB_CI_SHA256,
        downloaded_file_path = "gitlab-ci.schema.json",
    )
    http_file(
        name = "github_workflow_schema",
        urls = [_GITHUB_WORKFLOW_URL],
        sha256 = _GITHUB_WORKFLOW_SHA256,
        downloaded_file_path = "github-workflow.schema.json",
    )

ci_schemas = module_extension(implementation = _ci_schemas_impl)
