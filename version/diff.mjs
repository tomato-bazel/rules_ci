#!/usr/bin/env node
// diff.mjs — diff two SURFACE descriptors (see surface.mjs) → the set of API changes and the
// required SemVer bump. This is the DETERMINISTIC half of the versioning workflow:
//
//   • export REMOVED  → MAJOR   (breaking)            ─┐ decided here, no judgement needed
//   • export ADDED    → MINOR   (additive)            ─┘
//   • existing export's signature CHANGED → AMBIGUOUS  → escalate to the claude/MCP seem
//     (a shape change can be breaking OR additive — e.g. a new optional field vs a removed
//     param — and a text diff can't reliably tell; routing it to a judged verdict keeps the
//     deterministic layer CORRECT rather than guessing).
//
// `bump` is the deterministic FLOOR (max over add/remove). When `escalate` is true the real
// bump is max(bump, <verdict over the ambiguous changes>) — the orchestrator (version.mjs)
// resolves that via the escalation seam, then the tag-push workflow applies it.
import { readFileSync } from "node:fs";

const ORDER = { none: 0, patch: 1, minor: 2, major: 3 };
const maxBump = (a, b) => (ORDER[a] >= ORDER[b] ? a : b);

export function diffSurfaces(oldS, newS) {
  const oldByKey = new Map(oldS.exports.map((e) => [`${e.kind} ${e.name}`, e]));
  const newByKey = new Map(newS.exports.map((e) => [`${e.kind} ${e.name}`, e]));

  const changes = [];
  let bump = "none";

  for (const [key] of oldByKey) {
    if (!newByKey.has(key)) {
      changes.push({ op: "removed", symbol: key, implies: "major" });
      bump = maxBump(bump, "major");
    }
  }
  for (const [key] of newByKey) {
    if (!oldByKey.has(key)) {
      changes.push({ op: "added", symbol: key, implies: "minor" });
      bump = maxBump(bump, "minor");
    }
  }
  for (const [key, oldE] of oldByKey) {
    const newE = newByKey.get(key);
    if (newE && newE.signature !== oldE.signature) {
      changes.push({
        op: "changed",
        symbol: key,
        ambiguous: true,
        detail: { before: oldE.signature, after: newE.signature },
      });
    }
  }

  const ambiguous = changes.filter((c) => c.ambiguous);
  // Stable order: removed, added, changed; then by symbol.
  const rank = { removed: 0, added: 1, changed: 2 };
  changes.sort((a, b) => rank[a.op] - rank[b.op] || a.symbol.localeCompare(b.symbol));

  return {
    from_hash: oldS.surface_hash,
    to_hash: newS.surface_hash,
    bump, // deterministic floor; raise by the escalation verdict if escalate
    changes,
    ambiguous,
    escalate: ambiguous.length > 0,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [, , oldPath, newPath] = process.argv;
  if (!oldPath || !newPath) {
    console.error("usage: diff.mjs <old-surface.json> <new-surface.json>");
    process.exit(2);
  }
  const oldS = JSON.parse(readFileSync(oldPath, "utf8"));
  const newS = JSON.parse(readFileSync(newPath, "utf8"));
  console.log(JSON.stringify(diffSurfaces(oldS, newS), null, 2));
}
