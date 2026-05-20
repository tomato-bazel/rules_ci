# Lean 4 IR + correctness theorems

Placeholder. This directory will hold the Lean 4 formalization of
the IR (`CiIr.lean`), parser/emitter specifications, and the
structural correctness theorems described in
[`docs/DESIGN.md`](../docs/DESIGN.md).

The Lean side is **verifier**, not runtime. The Rust crates under
[`../translator/`](../translator/) are the production artifact.
Lean provides:

1. The IR's algebraic types as the canonical reference shape.
2. Theorems on parser totality, round-trip identity, and
   invariant preservation (level A in `docs/DESIGN.md`).
3. Reference implementations that property-based tests on the
   Rust side fuzz against.

When the formalization starts, it'll integrate with
[fastverk/rules_lean](https://github.com/fastverk/rules_lean) for
the build path.

Roadmap landing in v0.5.0+; v0.0.1 ships the design only.
