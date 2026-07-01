#!/usr/bin/env node
// surface.mjs — extract a normalized public-API SURFACE from a package's TypeScript .d.ts
// entry. The surface is the versioning contract: a sorted, comment/whitespace-normalized list
// of exported declarations (name + kind + signature) plus a stable hash. Two surfaces are
// diffed (see diff.mjs) to decide the required SemVer bump.
//
// Standalone Node ESM (no bazel, no extra deps beyond `typescript`, which every aion/* repo
// already has) — mirrors how tools/publish/publish.mjs runs in the CI lane. The .d.ts inputs
// come from the build graph: ReleaseArtifactInfo.surface (the rules_ci release_artifacts
// aspect captures the .d.ts* closure per npm product).
//
// SCHEMA NOTE (global "DTOs are protos" rule, exception (a)): the surface/diff DTOs stay plain
// JSON shaped to match the aion ecosystem's TS-first tooling, NOT a .proto — adding a proto
// toolchain to the fastverk `rules_ci` module for two TS-only tools isn't worth it. If a
// cross-language extractor (e.g. a Lean emit-boundary surface) later needs the same wire type,
// promote these shapes to `fastverk/release/v1/*.proto` then (the field names already line up).
import ts from "typescript";
import { createHash } from "node:crypto";

function kindOf(flags) {
  const F = ts.SymbolFlags;
  if (flags & F.Interface) return "interface";
  if (flags & F.Class) return "class";
  if (flags & F.TypeAlias) return "type";
  if (flags & F.Enum) return "enum";
  if (flags & F.Function) return "function";
  if (flags & (F.Variable | F.BlockScopedVariable)) return "const";
  if (flags & (F.Namespace | F.Module | F.ValueModule)) return "namespace";
  return "other";
}

// Strip comments + collapse whitespace so cosmetic edits (doc comments, reformatting,
// reordering whitespace) are NOT surface changes — only the real declaration shape is.
function normalize(text) {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function extractSurface(entry) {
  const program = ts.createProgram([entry], {
    noEmit: true,
    target: ts.ScriptTarget.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler,
    skipLibCheck: true,
  });
  const checker = program.getTypeChecker();
  const sf = program.getSourceFile(entry);
  if (!sf) throw new Error(`surface: cannot load entry ${entry}`);
  const moduleSymbol = checker.getSymbolAtLocation(sf);
  const symbols = moduleSymbol ? checker.getExportsOfModule(moduleSymbol) : [];

  const exportsOut = symbols.map((sym) => {
    const decls = sym.getDeclarations() || [];
    const signature = decls
      .map((d) => normalize(d.getText()))
      .sort()
      .join(" ; ");
    return { name: sym.getName(), kind: kindOf(sym.getFlags()), signature };
  });
  // Deterministic order so the hash + diff are stable regardless of source ordering.
  exportsOut.sort((a, b) => (a.name + a.kind).localeCompare(b.name + b.kind));

  const surface_hash = createHash("sha256")
    .update(JSON.stringify(exportsOut))
    .digest("hex")
    .slice(0, 16);
  return { entry, exports: exportsOut, surface_hash };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const binary = args.includes("--binary");
  const entry = args.find((a) => !a.startsWith("--"));
  if (!entry) {
    console.error("usage: surface.mjs <entry.d.ts> [--binary]");
    process.exit(2);
  }
  const surface = extractSurface(entry);
  if (binary) {
    // Emit the canonical proto wire form (the DTO IS a fastverk.release.v1.Surface). Lazy-import
    // so the JSON path needs no proto runtime; the descriptor comes from FASTVERK_RELEASE_DESCRIPTOR.
    const { loadRelease, toProto, encode } = await import("./proto.mjs");
    const { Surface } = loadRelease();
    process.stdout.write(encode(Surface, toProto.surface(surface)));
  } else {
    console.log(JSON.stringify(surface, null, 2));
  }
}
