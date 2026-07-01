#!/usr/bin/env node
// version.mjs — the versioning ORCHESTRATOR. Given a product's CURRENT public surface, its
// last-released surface, and the last-released version, compute the next version:
//
//   bump = max( deterministic add/remove bump (diff.mjs),
//               escalation verdict over the ambiguous shape-changes (escalate.mjs) )
//   next = applyBump(fromVersion, bump)
//
// Emits a VersionDecision the tag-push workflow consumes. The workflow (release CI lane)
// supplies `--previous` (the surface at the last tag — fetched by npm-pack'ing the last
// published version, or read from a stored release-surface artifact) and `--from`.
//
// 0.x SEMVER (every @aion/* package is 0.x today): the whole API is "unstable", so a breaking
// change DEGRADES to a minor bump and an additive one to a patch — the standard 0.x contract.
// Once a package hits 1.0.0 the normal mapping applies.
import { readFileSync } from "node:fs";
import { diffSurfaces } from "./diff.mjs";
import { escalate } from "./escalate.mjs";

const ORDER = { none: 0, patch: 1, minor: 2, major: 3 };
const maxBump = (a, b) => (ORDER[a] >= ORDER[b] ? a : b);

export function applyBump(version, bump) {
  const [maj, min, pat] = version.split(".").map(Number);
  const effective =
    maj === 0
      ? { none: "none", patch: "patch", minor: "patch", major: "minor" }[bump]
      : bump;
  if (effective === "major") return `${maj + 1}.0.0`;
  if (effective === "minor") return `${maj}.${min + 1}.0`;
  if (effective === "patch") return `${maj}.${min}.${pat + 1}`;
  return version;
}

export async function decideVersion({ product, fromVersion, previousSurface, currentSurface, escalateOpts }) {
  const diff = diffSurfaces(previousSurface, currentSurface);
  let bump = diff.bump;
  let escalated = false;
  let rationale;

  if (diff.escalate) {
    const verdict = await escalate(diff.ambiguous, escalateOpts);
    bump = maxBump(bump, verdict.bump);
    escalated = true;
    rationale = `${diff.ambiguous.length} ambiguous change(s) → ${verdict.backend === "none" ? "conservative" : "judged"} ${verdict.bump}: ${verdict.rationale}`;
  } else {
    rationale = bump === "none" ? "no public-surface change" : `deterministic ${bump} (add/remove only)`;
  }

  return {
    product,
    from_version: fromVersion,
    to_version: applyBump(fromVersion, bump),
    bump,
    escalated,
    tag: `${product}@${applyBump(fromVersion, bump)}`,
    changes: diff.changes,
    rationale,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    args[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
  }
  if (!args.previous || !args.current) {
    console.error("usage: version.mjs --product NAME --from X.Y.Z --previous prev.json --current cur.json");
    process.exit(2);
  }
  const decision = await decideVersion({
    product: args.product || "unknown",
    fromVersion: args.from || "0.0.0",
    previousSurface: JSON.parse(readFileSync(args.previous, "utf8")),
    currentSurface: JSON.parse(readFileSync(args.current, "utf8")),
  });
  console.log(JSON.stringify(decision, null, 2));
}
