#!/usr/bin/env node
// proto.mjs — the proto serialization BOUNDARY for the version/ tools.
//
// The fastverk.release.v1 messages are the canonical DTOs (see ../proto/.../release.proto).
// This module loads them from the HERMETICALLY-compiled descriptor set bazel emits
// (//proto/fastverk/release/v1:release_proto → release_proto-descriptor-set.proto.bin) — NOT a
// re-parse of the .proto text — so the schema the tools serialize against is exactly the one
// bazel's protoc validated. The tools keep ergonomic JS objects internally (lowercase enum
// strings); this boundary maps them to/from the proto messages and does proto-wire encode/decode.
//
// FASTVERK_RELEASE_DESCRIPTOR = path to the bazel descriptor set (the hermetic, canonical source).
// A .proto-text fallback exists for local dev only.
import protobuf from "protobufjs";
import descriptor from "protobufjs/ext/descriptor/index.js";
import { readFileSync } from "node:fs";

export const BUMP_TO_PROTO = { none: "NONE", patch: "PATCH", minor: "MINOR", major: "MAJOR" };
export const BUMP_FROM_PROTO = { BUMP_UNSPECIFIED: "none", NONE: "none", PATCH: "patch", MINOR: "minor", MAJOR: "major" };
export const OP_TO_PROTO = { added: "ADDED", removed: "REMOVED", changed: "CHANGED" };
export const OP_FROM_PROTO = { OP_UNSPECIFIED: "added", ADDED: "added", REMOVED: "removed", CHANGED: "changed" };

export function loadRelease({ descriptorPath, protoPath } = {}) {
  const dpath = descriptorPath || process.env.FASTVERK_RELEASE_DESCRIPTOR;
  let root;
  if (dpath) {
    const fds = descriptor.FileDescriptorSet.decode(readFileSync(dpath));
    root = protobuf.Root.fromDescriptor(fds);
  } else if (protoPath) {
    root = protobuf.loadSync(protoPath); // local-dev fallback (re-parses the .proto text)
  } else {
    throw new Error("proto.mjs: set FASTVERK_RELEASE_DESCRIPTOR (bazel descriptor set) or pass protoPath");
  }
  const T = (n) => root.lookupType("fastverk.release.v1." + n);
  return {
    root,
    Surface: T("Surface"),
    ReleaseManifest: T("ReleaseManifest"),
    SurfaceDiff: T("SurfaceDiff"),
    VersionDecision: T("VersionDecision"),
  };
}

// ── tool-object → proto-shaped object (lowercase enum strings → proto enum names) ──

function changeToProto(c) {
  return {
    op: OP_TO_PROTO[c.op] || "OP_UNSPECIFIED",
    symbol: c.symbol,
    implies: c.implies ? BUMP_TO_PROTO[c.implies] : "BUMP_UNSPECIFIED",
    ambiguous: !!c.ambiguous,
    // diff.mjs nests {detail:{before,after}}; the proto flattens to before/after.
    before: c.before != null ? c.before : c.detail ? c.detail.before : "",
    after: c.after != null ? c.after : c.detail ? c.detail.after : "",
  };
}

// NOTE: protobufjs exposes proto fields under their camelCase JS names (= the proto3-JSON
// canonical form), so the proto-shaped objects use camelCase keys (surfaceHash, fromHash, …)
// even though the .proto + the tools' own JSON use snake_case.
export const toProto = {
  surface: (s) => ({ surfaceHash: s.surface_hash, entry: s.entry || "", exports: s.exports || [] }),
  diff: (d) => ({
    fromHash: d.from_hash || "",
    toHash: d.to_hash || "",
    bump: BUMP_TO_PROTO[d.bump] || "NONE",
    changes: (d.changes || []).map(changeToProto),
    escalate: !!d.escalate,
  }),
  decision: (v) => ({
    product: v.product,
    fromVersion: v.from_version,
    toVersion: v.to_version,
    bump: BUMP_TO_PROTO[v.bump] || "NONE",
    escalated: !!v.escalated,
    tag: v.tag || "",
    changes: (v.changes || []).map(changeToProto),
    rationale: v.rationale || "",
  }),
};

// encode to proto wire bytes. fromObject FIRST (maps enum-name strings → numbers + coerces the
// shape), then verify the resulting message (enums are numbers by then), then encode.
export function encode(Type, protoObj) {
  const msg = Type.fromObject(protoObj);
  const err = Type.verify(msg);
  if (err) throw new Error(`proto.mjs: ${Type.name} does not conform: ${err}`);
  return Type.encode(msg).finish();
}

// decode proto wire bytes → a plain object (proto enum names as strings).
export function decode(Type, buf) {
  return Type.toObject(Type.decode(buf), { enums: String, defaults: true });
}
