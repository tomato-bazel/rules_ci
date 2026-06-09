//! Neutral IR for CI pipeline configuration.
//!
//! Mirrors the Lean 4 IR under `ir/`; the two are kept in sync by
//! convention. Property tests on the Rust side (in
//! `gitlab-parse` and the future `github-parse` / `*-emit`
//! crates) fuzz-generate schema-valid inputs and assert
//! invariants the Lean theorems prove on the IR.
//!
//! See [`docs/DESIGN.md`](../../docs/DESIGN.md) for the
//! semantic levels of correctness this IR commits to.
//!
//! Scope today: enough types for the v0.0.1 GitLab-CI-parse
//! scaffold + the aggregator binary. The Trigger/Rule/Cache
//! variants will fill in as the GitHub-Actions parser lands.
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

/// One end-to-end CI pipeline. The least-upper-bound of what a
/// `.gitlab-ci.yml` and a `.github/workflows/*.yml` express.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Pipeline {
    /// Ordered phase names. GitLab's `stages:`; GitHub's
    /// `jobs.<id>.needs:` graph is flattened into ordered
    /// stage-equivalent groups when emitting back to GitLab.
    #[serde(default)]
    pub stages: Vec<String>,

    /// Pipeline-level environment.
    #[serde(default)]
    pub variables: IndexMap<String, String>,

    /// Cross-pipeline composition: `include:` (GitLab) /
    /// reusable workflow refs (GitHub).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub includes: Vec<Include>,

    /// Triggers — which events run the pipeline. GitLab's
    /// `workflow.rules:`; GitHub's `on:`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub triggers: Vec<Trigger>,

    /// The default job shape applied to every job before its own
    /// overrides. GitLab's `default:`. GitHub doesn't have a
    /// direct analogue (no implicit job inheritance); emit-side
    /// expands `default` into each job.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<JobShape>,

    /// Hidden-job templates (keys starting with `.` in GitLab).
    /// Materialized into jobs via `extends:` resolution at parse
    /// time; preserved here for round-trip fidelity.
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub templates: IndexMap<String, JobShape>,

    /// Real jobs, in the order they appear in the source.
    pub jobs: IndexMap<String, Job>,
}

/// A concrete job — a `Job` is a `JobShape` plus a name.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Job {
    pub name: String,
    #[serde(flatten)]
    pub shape: JobShape,
}

/// The attributes a job carries. Split from `Job` so that
/// `Pipeline.default` and `Pipeline.templates` can share the same
/// shape without name-specific bookkeeping.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobShape {
    /// Which stage / phase this job belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<String>,

    /// Predecessor jobs (GitLab `needs:` / `dependencies:` /
    /// GitHub `needs:`). Names refer to other jobs in the same
    /// `Pipeline.jobs`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub needs: Vec<String>,

    /// Container image / runner image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,

    /// Job-level env.
    #[serde(default, skip_serializing_if = "IndexMap::is_empty")]
    pub env: IndexMap<String, String>,

    /// Shell commands. Treated as opaque strings — the IR makes
    /// no semantic claims about what the commands do.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub script: Vec<String>,

    /// Commands run before `script`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub before_script: Vec<String>,

    /// Commands run after `script`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub after_script: Vec<String>,

    /// Files / paths the job exposes for downstream jobs.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub artifacts: Vec<String>,

    /// `when:` / `if:` clauses on the job. Kept as opaque
    /// strings for v0.0.1 — Trigger-level structure lands when
    /// the GitHub parser does.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rules: Vec<String>,

    /// Structured publish target — the one "ship a built artifact to a
    /// hosting surface" concern that GitLab and GitHub express very
    /// differently (so it earns the IR its keep). `None` for ordinary
    /// jobs. Emitters render it per platform; see `Publish`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publish: Option<Publish>,
}

/// A structured publish target. The IR models the *intent* — "publish this
/// directory as the repo's static site" — and each emitter renders the
/// platform-specific mechanism. This is the canonical case of the IR hiding
/// genuine divergence: GitLab Pages is a magic `pages` job whose `public/`
/// artifact is served; GitHub Pages is a workflow that runs
/// `actions/upload-pages-artifact` then `actions/deploy-pages` with
/// `permissions: { pages: write, id-token: write }` and a `github-pages`
/// environment.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum Publish {
    /// Publish a directory as the repository's Pages site.
    Pages {
        /// Directory (relative to the job's working dir) holding the
        /// rendered site root, with `index.html` at its top level.
        path: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Include {
    Local { path: String },
    Project { project: String, file: String, ref_: Option<String> },
    Remote { url: String },
    Template { name: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Trigger {
    Push { branches: Vec<String>, tags: Vec<String> },
    PullRequest { branches: Vec<String> },
    Schedule { cron: String },
    Manual,
    Other { name: String, raw: serde_json::Value },
}

/// Surface-level invariants the IR enforces. Mirrors the
/// structural correctness theorems planned for Lean.
pub fn validate(pipeline: &Pipeline) -> Vec<String> {
    let mut diagnostics = Vec::new();

    // Every `needs:` target must name a job that exists.
    for (job_name, job) in &pipeline.jobs {
        for need in &job.shape.needs {
            if !pipeline.jobs.contains_key(need) {
                diagnostics.push(format!(
                    "job {job_name:?}: needs nonexistent job {need:?}"
                ));
            }
        }
        if let Some(stage) = &job.shape.stage {
            if !pipeline.stages.is_empty() && !pipeline.stages.contains(stage) {
                diagnostics.push(format!(
                    "job {job_name:?}: stage {stage:?} not in pipeline stages ({:?})",
                    pipeline.stages,
                ));
            }
        }
    }

    // No cycles in the `needs:` graph. Simple DFS.
    let mut visited = std::collections::HashSet::new();
    let mut stack = std::collections::HashSet::new();
    for job in pipeline.jobs.keys() {
        if let Some(cycle) = find_cycle(job, &pipeline.jobs, &mut visited, &mut stack) {
            diagnostics.push(format!("cycle in needs: graph: {}", cycle.join(" -> ")));
        }
    }

    diagnostics
}

fn find_cycle(
    node: &str,
    jobs: &IndexMap<String, Job>,
    visited: &mut std::collections::HashSet<String>,
    on_stack: &mut std::collections::HashSet<String>,
) -> Option<Vec<String>> {
    if on_stack.contains(node) {
        return Some(vec![node.to_string()]);
    }
    if visited.contains(node) {
        return None;
    }
    visited.insert(node.to_string());
    on_stack.insert(node.to_string());
    if let Some(job) = jobs.get(node) {
        for next in &job.shape.needs {
            if let Some(mut cycle) = find_cycle(next, jobs, visited, on_stack) {
                cycle.push(node.to_string());
                return Some(cycle);
            }
        }
    }
    on_stack.remove(node);
    None
}
