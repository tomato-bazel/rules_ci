"""The fastverk RBE execution platform, defined once.

WHY THIS IS SHARED AND NOT PER-REPO. `container-image` is not a preference — it is
the buildbarn scheduler's ROUTING KEY and part of the RBE action-cache key. It must
byte-match the worker pool's advertised platform, or the scheduler answers "No
workers exist for … container-image=…" and nothing runs.

A value with that property, copied into every consuming repo, drifts — and it has.
When this was written, `aion/lean` and `aion/e2e` both declared
`docker://ghcr.io/catthehacker/ubuntu:act-22.04` while `RbeCluster/fastverk`'s
worker advertised
`docker://…/tbzl-rbe-worker:act-22.04-libtinfo5-py3`. Those are two DIFFERENT pools:
the second carries the libtinfo5 + python3 layers the prebuilt LLVM clang and
genrule-shell-outs need, and the first is stock upstream Ubuntu. So the repo whose
whole reason for using RBE is heavy Lean/clang actions was routing to the pool
WITHOUT the library that clang links — a risk its own comment flagged as unproven,
and which was live.

Nothing catches that today, because a wrong-but-valid string is not a build error;
it is a routing decision that silently lands somewhere else. One definition is what
makes it a single, reviewable fact instead of N copies that agree by luck.

VERIFY against the cluster (this is the source of truth, not this file):

    kubectl -n fastverk get rbecluster fastverk \\
      -o jsonpath='{.spec.worker.containerImage}'
    kubectl get workerpool -A \\
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containerImage}{"\\n"}{end}'
"""

# The advertised platform of RbeCluster/fastverk's worker pool.
#
# A MUTABLE TAG, deliberately recorded as such rather than silently pinned: the
# rbe-api contract says "Prefer a digest pin", and the fleet does not. That is a real
# tradeoff, not an oversight — the platform string is part of every action-cache key,
# so pinning by digest means any image change (a font package, a CA bundle) discards
# the entire action cache, whereas a tag keeps the cache across environment bumps at
# the cost of the environment not being pinned by the key.
#
# The consequence to know: rebuilding this tag changes what executes while every
# cache key stays identical. With HERMETIC toolchains that is survivable — the
# compiler arrives as an action input from the CAS regardless of the image. It stops
# being survivable the moment a toolchain comes from the image instead, because then
# the compiler's identity lives only in this string. So this constant is the thing
# that has to become a digest BEFORE host toolchains are safe.
FASTVERK_RBE_CONTAINER_IMAGE = "docker://042825952740.dkr.ecr.us-east-1.amazonaws.com/tbzl-rbe-worker:act-22.04-libtinfo5-py3"

# The exec_properties the buildbarn scheduler routes on.
FASTVERK_RBE_EXEC_PROPERTIES = {
    "OSFamily": "linux",
    "container-image": FASTVERK_RBE_CONTAINER_IMAGE,
}
