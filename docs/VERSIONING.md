# Automated versioning + tag-push (rules_ci)

A WORKFLOW pushes `pkg@x.y.z` tags — never a dev, never the user. On merge to protected
`main`, per discovered product, the pipeline computes the required SemVer bump from the
PUBLIC SURFACE diff and pushes the tag under a bot identity; the existing idempotent
publish lane fires on the tag. This replaces hand-maintained version bumps and manual
changeset files with a deterministic, surface-driven decision (escalating only the
genuinely-ambiguous cases to a judged verdict).

## Pipeline

```
merge to main
   │
   ▼
release_artifacts aspect  ──►  per npm product: { name, version_source(package.json), surface(.d.ts*) }
   │
   ▼
version/surface.mjs  ──►  CURRENT surface (normalized exported decls + hash)   [per product]
   │                       fetch PREVIOUS surface (npm pack last tag → .d.ts, or stored artifact)
   ▼
version/diff.mjs    ──►  changes + DETERMINISTIC bump floor
   │                      • removed export → major   • added export → minor
   │                      • changed shape  → AMBIGUOUS
   ▼
version/escalate.mjs ──►  resolve ambiguous → bump  (conservative default, OR judged verdict)
   │
   ▼
version/version.mjs ──►  VersionDecision { from, to, bump, tag, rationale }   [0.x degrade]
   │
   ▼
tag-push (bot identity, tag-protection-admitted) ──►  publish lane fires on `pkg@x.y.z`
```

## The deterministic core (BUILT + PROVEN — `version/`)

- **`surface.mjs`** — extracts the public surface from a package's `.d.ts` entry via the TS
  compiler API: a sorted, comment/whitespace-NORMALIZED list of exported declarations
  (`{name, kind, signature}`) + a stable `surface_hash`. Cosmetic edits (doc comments,
  reformatting) are NOT surface changes. The `.d.ts` inputs come from the build graph
  (`ReleaseArtifactInfo.surface`, captured by the `release_artifacts` aspect).
- **`diff.mjs`** — diffs two surfaces → changes + a SemVer bump. DETERMINISTIC for
  add/remove (added→minor, removed→major); a shape CHANGE of an existing export is marked
  `ambiguous` (a text diff can't reliably tell breaking from additive) and routed to escalation.
- **`escalate.mjs`** — the AMBIGUOUS-change seam. SAFE BY DEFAULT (no AI required): absent a
  backend, ambiguous → conservative `FASTVERK_VERSION_AMBIGUOUS_DEFAULT` (default `major`) so
  it never under-bumps. PRECISE WHEN WIRED: `FASTVERK_VERSION_ESCALATE_CMD` (the headless
  `claude -p` entrypoint) gets the ambiguous changes on stdin, returns `{bump, rationale}`.
- **`version.mjs`** — orchestrator: `bump = max(deterministic, escalation)`, then
  `applyBump` with **0.x SemVer degradation** (every @aion/* package is 0.x: breaking→minor,
  additive→patch; normal mapping once a package hits 1.0.0). Emits a `VersionDecision`.

Proven on `version/fixtures/{base,add,remove,change}.d.ts`:
`add`→0.2.6, `remove`→0.3.0, `change`(no backend)→0.3.0 conservative,
`change`(wired backend says minor)→0.2.6, no-change@1.4.0→1.4.0.

## Schema — the DTOs ARE protos (`fastverk.release.v1`)

The surface/diff/decision DTOs cross the build→tool→tag boundary, so per "DTOs are protos"
they are the canonical **`proto/fastverk/release/v1/release.proto`** messages (Surface,
TsExport, Product, ReleaseManifest, SurfaceChange, SurfaceDiff, VersionDecision) — the schema
of record, not ad-hoc JSON.

- **Compiled HERMETICALLY by bazel** — `//proto/fastverk/release/v1:release_proto` (rules_proto
  7.1.0 + protobuf 33.4; protoc from the toolchain, never the system one). The build emits
  `release_proto-descriptor-set.proto.bin`, the single cross-language source of truth.
- **The Node `version/` tools serialize via that descriptor** — `version/proto.mjs` loads the
  bazel-emitted descriptor set with protobufjs (no `.proto` re-parse, no codegen step) and
  does proto-wire `encode`/`decode` + `verify` at the I/O boundary. The tools keep ergonomic
  JS objects internally (lowercase enum strings); `proto.mjs` maps them to the proto messages
  (camelCase fields = the proto3-JSON canonical form; `Bump`/`Op` enum-name maps).
- **Cross-language ready:** a future Lean emit-boundary surface extractor consumes the same
  descriptor — add a Lean arm field to `Surface` (proto3 forward-compat) when it lands.
- Proven: `surface.mjs --binary` emits a `Surface` on the wire; Surface/SurfaceDiff/
  VersionDecision all round-trip encode→decode, and `verify()` rejects malformed messages.

## The escalation backend (GREENFIELD — designed, not built)

There is NO `fastverk/mcp` repo today (confirmed). The seam is ready; the backend is the next
infra step:
- A small headless entrypoint: `claude -p` given ONLY the ambiguous changes + a strict
  JSON-schema'd `{bump, rationale}` output, scoped by an MCP ensemble (fastverk/build's bazel
  query/cquery + surface introspection) so it answers from the graph, not guesses.
- Verdict is a pure function of the ambiguous-change set → cache by `surface_hash` pair.
- Baked into the CI image (infra/images → aion/build) and exposed as
  `FASTVERK_VERSION_ESCALATE_CMD`. Until then the conservative default keeps releases SAFE.

## Tag-push + bot identity (GATED — outward config)

- The release lane (`ci/aion-release.gitlab-ci.yml`) runs on main, computes the decision,
  writes `package.json` `version`, and pushes `pkg@x.y.z`. The proven tag-push pattern (from
  platform/studio `release.yml`): `git push origin <tag>` under a token; on tag-collision
  append a timestamp suffix. The existing idempotent `publish.mjs` fires on the tag.
- **Bot identity:** a dedicated release-bot user (recommended) or the [[aion-carve-ci-token]]
  group-195 token, admitted by **tag protection** (`v*` / `*@*` tags pushable only by the bot).
  Tag protection + the bot user are the gated outward steps (no git tags exist in the carves
  yet; main is Maintainer-only).
- **Previous-surface source:** the lane `npm pack`s the last published version and extracts its
  `.d.ts` for `--previous` (no rebuild-at-tag needed). Alternative: store the surface JSON as a
  release artifact per tag.

## Rollout (gated)

1. Bake `version/*.mjs` + `publish.mjs` into the CI image (stop per-repo vendoring).
2. Add the release lane to the shared aion CI templates (`include:`-ed by every repo).
3. Stand up the escalation backend; set `FASTVERK_VERSION_ESCALATE_CMD`.
4. Create the release-bot identity + tag protection.
5. Pilot on one carve, then fan out via wave/forge.
