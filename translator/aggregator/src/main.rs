//! `ci_aggregator` — fleet CI analysis. Reads N member
//! `.gitlab-ci.yml` files, normalizes them through the
//! `rules_ci_ir` IR, and emits both a machine-readable JSON
//! projection and a Markdown similarity report.
//!
//! Drop-in Rust replacement for the Python aggregator that lived
//! in savvi's `ci_analysis/private/aggregate.py`. Same CLI
//! surface (`--member NAME=PATH --json-out PATH --report-out PATH`),
//! same output shape — but built on the IR so the same parser
//! that powers the future translators powers the report.

use anyhow::{bail, Context, Result};
use clap::Parser;
use ci_ir::Pipeline;
use indexmap::{IndexMap, IndexSet};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(about, long_about = None)]
struct Args {
    /// `NAME=PATH` to a `.gitlab-ci.yml`. Repeat for each member.
    #[arg(long = "member", required = true)]
    member: Vec<String>,

    /// Where to write the JSON projection.
    #[arg(long)]
    json_out: PathBuf,

    /// Where to write the Markdown report.
    #[arg(long)]
    report_out: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mut entries: Vec<(String, Pipeline)> = Vec::new();
    for raw in &args.member {
        let (name, path) = raw
            .split_once('=')
            .with_context(|| format!("bad --member entry {raw:?} (expected NAME=PATH)"))?;
        if name.is_empty() || path.is_empty() {
            bail!("--member NAME=PATH has empty field: {raw:?}");
        }
        let yaml = fs::read_to_string(path)
            .with_context(|| format!("reading {path}"))?;
        let pipeline = gitlab_parse::parse(&yaml)
            .with_context(|| format!("parsing {path}"))?;
        entries.push((name.to_string(), pipeline));
    }

    // Sort by member name for byte-stable output.
    entries.sort_by(|a, b| a.0.cmp(&b.0));

    write_json(&args.json_out, &entries)?;
    write_report(&args.report_out, &entries)?;
    Ok(())
}

#[derive(serde::Serialize)]
struct FleetJson<'a> {
    members: Vec<MemberJson<'a>>,
}

#[derive(serde::Serialize)]
struct MemberJson<'a> {
    member: &'a str,
    #[serde(flatten)]
    pipeline: &'a Pipeline,
}

fn write_json(path: &std::path::Path, entries: &[(String, Pipeline)]) -> Result<()> {
    let body = FleetJson {
        members: entries
            .iter()
            .map(|(name, p)| MemberJson { member: name, pipeline: p })
            .collect(),
    };
    let pretty = serde_json::to_string_pretty(&body)?;
    fs::write(path, format!("{pretty}\n"))?;
    Ok(())
}

fn write_report(path: &std::path::Path, entries: &[(String, Pipeline)]) -> Result<()> {
    let mut out = String::from("# Fleet CI report\n\n");
    let members: Vec<&str> = entries.iter().map(|(n, _)| n.as_str()).collect();

    // ---- Stages × member matrix
    let mut all_stages: IndexSet<String> = IndexSet::new();
    for (_, p) in entries {
        for s in &p.stages {
            all_stages.insert(s.clone());
        }
    }
    let mut stages_sorted: Vec<&String> = all_stages.iter().collect();
    stages_sorted.sort();
    if !stages_sorted.is_empty() {
        out.push_str("## Stages\n\n");
        out.push_str("| stage | ");
        out.push_str(&members.join(" | "));
        out.push_str(" |\n");
        out.push_str("|");
        for _ in 0..=members.len() {
            out.push_str("---|");
        }
        out.push('\n');
        for stage in &stages_sorted {
            out.push_str(&format!("| `{stage}` | "));
            let cells: Vec<&str> = entries
                .iter()
                .map(|(_, p)| if p.stages.contains(*stage) { "✓" } else { "" })
                .collect();
            out.push_str(&cells.join(" | "));
            out.push_str(" |\n");
        }
        out.push('\n');
    }

    // ---- Cross-project includes
    out.push_str("## Cross-project includes\n\n");
    for (name, p) in entries {
        if p.includes.is_empty() {
            out.push_str(&format!("- **{name}**: _none_\n"));
            continue;
        }
        out.push_str(&format!("- **{name}**:\n"));
        for inc in &p.includes {
            out.push_str(&format!("  - `{}`\n", render_include(inc)));
        }
    }
    out.push('\n');

    // ---- Jobs in multiple members
    let mut job_owners: IndexMap<&str, Vec<&str>> = IndexMap::new();
    for (name, p) in entries {
        for job in p.jobs.keys() {
            job_owners
                .entry(job.as_str())
                .or_default()
                .push(name.as_str());
        }
    }
    let mut shared: Vec<(&&str, &Vec<&str>)> = job_owners
        .iter()
        .filter(|(_, owners)| owners.len() >= 2)
        .collect();
    shared.sort_by(|a, b| (b.1.len(), a.0).cmp(&(a.1.len(), b.0)));
    if !shared.is_empty() {
        out.push_str("## Job names appearing in multiple members\n\n");
        out.push_str("| job | members |\n|---|---|\n");
        for (job, owners) in &shared {
            out.push_str(&format!("| `{job}` | {} |\n", owners.join(", ")));
        }
        out.push('\n');
    }

    // ---- Variables in multiple members
    let mut var_count: HashMap<&str, usize> = HashMap::new();
    for (_, p) in entries {
        for v in p.variables.keys() {
            *var_count.entry(v.as_str()).or_default() += 1;
        }
    }
    let mut shared_vars: Vec<(&&str, &usize)> =
        var_count.iter().filter(|(_, c)| **c >= 2).collect();
    shared_vars.sort_by(|a, b| (b.1, a.0).cmp(&(a.1, b.0)));
    if !shared_vars.is_empty() {
        out.push_str("## Variables defined in multiple members\n\n");
        out.push_str("| variable | member count |\n|---|---|\n");
        for (v, c) in &shared_vars {
            out.push_str(&format!("| `{v}` | {c} |\n"));
        }
        out.push('\n');
    }

    // ---- Per-member summary
    out.push_str("## Per-member summary\n\n");
    out.push_str("| member | stages | jobs | templates | includes | variables |\n");
    out.push_str("|---|---|---|---|---|---|\n");
    for (name, p) in entries {
        out.push_str(&format!(
            "| **{name}** | {} | {} | {} | {} | {} |\n",
            p.stages.len(),
            p.jobs.len(),
            p.templates.len(),
            p.includes.len(),
            p.variables.len(),
        ));
    }

    fs::write(path, out)?;
    Ok(())
}

fn render_include(inc: &ci_ir::Include) -> String {
    match inc {
        ci_ir::Include::Local { path } => path.clone(),
        ci_ir::Include::Project { project, file, ref_ } => match ref_ {
            Some(r) => format!("{project}@{r} :: {file}"),
            None => format!("{project} :: {file}"),
        },
        ci_ir::Include::Remote { url } => url.clone(),
        ci_ir::Include::Template { name } => format!("template:{name}"),
    }
}
