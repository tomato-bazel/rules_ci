#!/usr/bin/env node
// escalate.mjs — the AMBIGUOUS-change escalation SEAM.
//
// The deterministic layer (diff.mjs) classifies add/remove precisely and routes
// shape-CHANGES of existing exports here, because a text diff can't reliably tell a breaking
// change from an additive one. This seam resolves those into a precise bump.
//
// SAFE BY DEFAULT — no AI required: absent a configured backend, ambiguous changes take a
// CONSERVATIVE default (FASTVERK_VERSION_AMBIGUOUS_DEFAULT, default "major") so the workflow
// NEVER under-bumps (it may over-bump until the backend is wired — safe, not silent breakage).
//
// PRECISE WHEN WIRED: set FASTVERK_VERSION_ESCALATE_CMD to a headless verdict command (the
// `claude -p` entrypoint scoped by the fastverk MCP ensemble — GREENFIELD, see VERSIONING.md).
// The ambiguous changes are piped to it as JSON on stdin; it returns `{"bump","rationale"}`.
// The verdict is a pure function of the ambiguous-change set, so it caches by surface-hash.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const VALID = ["none", "patch", "minor", "major"];

export async function escalate(ambiguousChanges, opts = {}) {
  const fallback = opts.default || process.env.FASTVERK_VERSION_AMBIGUOUS_DEFAULT || "major";
  const cmd = opts.cmd || process.env.FASTVERK_VERSION_ESCALATE_CMD;

  if (!cmd) {
    return {
      bump: fallback,
      backend: "none",
      rationale:
        `no escalation backend (FASTVERK_VERSION_ESCALATE_CMD unset) — conservative ` +
        `default "${fallback}" over ${ambiguousChanges.length} ambiguous change(s)`,
    };
  }

  const payload = JSON.stringify({ ambiguous: ambiguousChanges });
  const out = execSync(cmd, { input: payload, encoding: "utf8" });
  const verdict = JSON.parse(out);
  if (!VALID.includes(verdict.bump)) {
    throw new Error(`escalation backend returned invalid bump: ${JSON.stringify(verdict.bump)}`);
  }
  return {
    bump: verdict.bump,
    backend: cmd,
    rationale: verdict.rationale || "(escalation backend verdict, no rationale given)",
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const input = JSON.parse(readFileSync(0, "utf8"));
  escalate(input.ambiguous || []).then((v) => console.log(JSON.stringify(v, null, 2)));
}
