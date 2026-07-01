//! Parse `.gitlab-ci.yml` into the rules_ci IR.
//!
//! Scope: structural projection. GitLab's reserved top-level
//! keywords (`stages`, `variables`, `include`, `default`,
//! `workflow`, `image`, `services`, `before_script`,
//! `after_script`, `cache`, `pages`, `spec`) become Pipeline
//! fields; everything else at the top level is a job (or a hidden
//! template if its key starts with `.`).
//!
//! Custom YAML tags. GitLab CI accepts non-standard tags
//! (`!reference [.aws_env, before_script]`, `!file`, `!base64`).
//! serde_yaml 0.9 rejects unknown tags by default. We work
//! around this by pre-parsing into `serde_yaml::Value` (which
//! tolerates tagged scalars/sequences/mappings) and projecting
//! into the IR by hand.
use anyhow::{Context, Result};
use ci_ir::{Include, Job, JobShape, Pipeline};
use indexmap::IndexMap;
use serde_yaml::Value;

const RESERVED: &[&str] = &[
    "stages",
    "variables",
    "default",
    "include",
    "workflow",
    "image",
    "services",
    "before_script",
    "after_script",
    "cache",
    "pages",
    "spec",
];

/// Parse a `.gitlab-ci.yml` source string into a `Pipeline`.
pub fn parse(source: &str) -> Result<Pipeline> {
    let root: Value = serde_yaml::from_str(source).context("parsing YAML")?;
    let map = root
        .as_mapping()
        .context("top-level must be a YAML mapping")?;

    let mut pipeline = Pipeline::default();

    for (k, v) in map {
        let key = k.as_str().context("non-string top-level key")?.to_string();
        match key.as_str() {
            "stages" => {
                pipeline.stages = string_list(v)?;
            }
            "variables" => {
                pipeline.variables = string_map(v)?;
            }
            "include" => {
                pipeline.includes = parse_includes(v)?;
            }
            "default" => {
                pipeline.default = Some(parse_job_shape(v)?);
            }
            "workflow" | "image" | "services" | "before_script" | "after_script"
            | "cache" | "pages" | "spec" => {
                // Reserved but not yet projected into the IR.
                // Surface in diagnostics as we add explicit
                // support per-roadmap.
            }
            _ if key.starts_with('.') => {
                pipeline.templates.insert(key.clone(), parse_job_shape(v)?);
            }
            _ => {
                let shape = parse_job_shape(v)?;
                pipeline.jobs.insert(
                    key.clone(),
                    Job {
                        name: key,
                        shape,
                    },
                );
            }
        }
    }

    Ok(pipeline)
}

fn string_list(v: &Value) -> Result<Vec<String>> {
    let Some(seq) = v.as_sequence() else {
        anyhow::bail!("expected sequence, got {:?}", v);
    };
    Ok(seq
        .iter()
        .filter_map(|x| x.as_str().map(str::to_string))
        .collect())
}

fn string_map(v: &Value) -> Result<IndexMap<String, String>> {
    let Some(map) = v.as_mapping() else {
        anyhow::bail!("expected mapping, got {:?}", v);
    };
    let mut out = IndexMap::new();
    for (k, val) in map {
        if let (Some(k), Some(v)) = (k.as_str(), val_as_scalar_string(val)) {
            out.insert(k.to_string(), v);
        }
    }
    Ok(out)
}

fn val_as_scalar_string(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Number(n) => Some(n.to_string()),
        Value::Null => Some(String::new()),
        // Tagged + complex values get serialized lossily — good
        // enough for v0.0.1; round-trip fidelity for these is
        // tracked in v0.2.
        _ => Some(serde_yaml::to_string(v).ok()?.trim().to_string()),
    }
}

fn parse_includes(v: &Value) -> Result<Vec<Include>> {
    let normalize = |single: &Value| -> Result<Include> {
        if let Some(s) = single.as_str() {
            return Ok(Include::Local { path: s.to_string() });
        }
        if let Some(map) = single.as_mapping() {
            let proj = map.get(Value::String("project".into()))
                .and_then(Value::as_str);
            let file = map.get(Value::String("file".into()))
                .and_then(Value::as_str);
            let ref_ = map.get(Value::String("ref".into()))
                .and_then(Value::as_str)
                .map(str::to_string);
            if let (Some(proj), Some(file)) = (proj, file) {
                return Ok(Include::Project {
                    project: proj.to_string(),
                    file: file.to_string(),
                    ref_,
                });
            }
            if let Some(local) = map.get(Value::String("local".into())).and_then(Value::as_str) {
                return Ok(Include::Local { path: local.to_string() });
            }
            if let Some(remote) = map.get(Value::String("remote".into())).and_then(Value::as_str) {
                return Ok(Include::Remote { url: remote.to_string() });
            }
            if let Some(tpl) = map.get(Value::String("template".into())).and_then(Value::as_str) {
                return Ok(Include::Template { name: tpl.to_string() });
            }
        }
        anyhow::bail!("unrecognized include entry: {:?}", single)
    };

    match v {
        Value::Sequence(items) => items.iter().map(normalize).collect(),
        other => Ok(vec![normalize(other)?]),
    }
}

fn parse_job_shape(v: &Value) -> Result<JobShape> {
    let mut shape = JobShape::default();
    let Some(map) = v.as_mapping() else {
        // Single scalar or sequence as a "job" — empty shape.
        return Ok(shape);
    };
    for (k, val) in map {
        let Some(key) = k.as_str() else { continue };
        match key {
            "stage" => shape.stage = val.as_str().map(str::to_string),
            "image" => shape.image = val.as_str().map(str::to_string),
            "needs" => shape.needs = string_list(val).unwrap_or_default(),
            "variables" | "env" => shape.env = string_map(val).unwrap_or_default(),
            "script" => shape.script = string_list(val).unwrap_or_default(),
            "before_script" => shape.before_script = string_list(val).unwrap_or_default(),
            "after_script" => shape.after_script = string_list(val).unwrap_or_default(),
            "rules" => {
                // For now flatten to opaque strings — full Trigger/Rule
                // typing lands when github-parse defines the symmetric
                // shape.
                if let Some(seq) = val.as_sequence() {
                    shape.rules = seq
                        .iter()
                        .map(|x| serde_yaml::to_string(x).unwrap_or_default().trim().to_string())
                        .collect();
                }
            }
            "artifacts" => {
                if let Some(map) = val.as_mapping() {
                    if let Some(paths) = map.get(Value::String("paths".into())) {
                        shape.artifacts = string_list(paths).unwrap_or_default();
                    }
                }
            }
            _ => {}
        }
    }
    Ok(shape)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minimal_pipeline_parses() {
        let src = r#"
stages:
  - build
  - test

variables:
  APP: demo

build:
  stage: build
  script:
    - echo hello

test:
  stage: test
  needs:
    - build
  script:
    - echo world
"#;
        let p = parse(src).unwrap();
        assert_eq!(p.stages, vec!["build", "test"]);
        assert_eq!(p.variables.get("APP"), Some(&"demo".to_string()));
        assert_eq!(p.jobs.len(), 2);
        assert_eq!(p.jobs["test"].shape.needs, vec!["build"]);
        let diagnostics = ci_ir::validate(&p);
        assert!(diagnostics.is_empty(), "{:?}", diagnostics);
    }

    #[test]
    fn dangling_needs_diagnosed() {
        let src = r#"
stages:
  - build
  - test

test:
  stage: test
  needs:
    - missing
  script:
    - true
"#;
        let p = parse(src).unwrap();
        let diagnostics = ci_ir::validate(&p);
        assert!(
            diagnostics.iter().any(|d| d.contains("missing")),
            "expected dangling-needs diagnostic, got {:?}",
            diagnostics,
        );
    }
}
