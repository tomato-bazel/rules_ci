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
#
# Pin to an immutable release TAG, never `master` — `master` is a
# moving ref whose content changes silently break the sha256 pin (the
# build then fails to fetch). Bump _GITLAB_CI_TAG + _GITLAB_CI_SHA256
# together to refresh:
#   curl -fsSL "https://gitlab.com/gitlab-org/gitlab-foss/-/raw/$TAG/app/assets/javascripts/editor/schema/ci.json" | shasum -a 256
_GITLAB_CI_TAG = "v18.11.5"
_GITLAB_CI_URL = "https://gitlab.com/gitlab-org/gitlab-foss/-/raw/{}/app/assets/javascripts/editor/schema/ci.json".format(_GITLAB_CI_TAG)
_GITLAB_CI_SHA256 = "fe7dcbabd9e0b441b59395a335d5cd480a770b90d9707f2511969a1564066a53"

# Curated GitHub Actions workflow schema (SchemaStore's mirror —
# more stable than GitHub's own internal one, used by every major
# JSON Schema-driven YAML language server).
#
# Pin to an immutable SchemaStore commit, never the live
# `json.schemastore.org/github-workflow.json` endpoint — that endpoint
# is a moving "latest" whose content changes silently break the sha256
# pin. Bump _GITHUB_WORKFLOW_COMMIT + _GITHUB_WORKFLOW_SHA256 together:
#   curl -fsSL "https://raw.githubusercontent.com/SchemaStore/schemastore/$COMMIT/src/schemas/json/github-workflow.json" | shasum -a 256
_GITHUB_WORKFLOW_COMMIT = "dbc0fd17b1c6b5f2fe151ffd0e504ca01c777151"
_GITHUB_WORKFLOW_URL = "https://raw.githubusercontent.com/SchemaStore/schemastore/{}/src/schemas/json/github-workflow.json".format(_GITHUB_WORKFLOW_COMMIT)
_GITHUB_WORKFLOW_SHA256 = "72ddb93afca7270a62b319175a6edc99e2fe802e5b58a6078e904cd726e10462"

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
