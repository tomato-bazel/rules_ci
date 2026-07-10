#!/usr/bin/env bash
# Generic publish dispatcher for `ci_publish(...)` targets.
#
# Invoked via `bazel run` by the fastverk build-runner, which supplies the AWS / GitHub
# credentials in the environment. Without credentials it logs the intended action and exits 0
# (a safe no-op) so a local `bazel run` is harmless. The build-runner may instead read the
# pipeline's `<name>.pipeline.json` and drive the same operations itself — this script is the
# reference implementation of each `kind`.
set -euo pipefail

KIND= ARTIFACT= DEST= REPO= TAG= ASSET=
# `--flag=value` single tokens (ci_publish passes them this way) so empty values are preserved.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind=*) KIND="${1#*=}" ;;
    --artifact=*) ARTIFACT="${1#*=}" ;;
    --destination=*) DEST="${1#*=}" ;;
    --repo=*) REPO="${1#*=}" ;;
    --tag=*) TAG="${1#*=}" ;;
    --asset=*) ASSET="${1#*=}" ;;
    *) echo "publish_runner: unknown arg '$1'" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[publish_runner] $*" >&2; }

# `have <tool>` is false in dry-run mode (FASTVERK_PUBLISH_DRYRUN=1) so every kind takes its
# log-only branch — lets `bazel run` / the build-runner preview a publish without credentials.
have() { [[ -z "${FASTVERK_PUBLISH_DRYRUN:-}" ]] && command -v "$1" >/dev/null 2>&1; }

# Resolve the artifact path — under `bazel run` the file is in the runfiles tree.
resolve() {
  local p="$1"
  [[ -f "$p" ]] && { echo "$p"; return; }
  [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" && -f "$BUILD_WORKSPACE_DIRECTORY/$p" ]] && { echo "$BUILD_WORKSPACE_DIRECTORY/$p"; return; }
  local rf="$0.runfiles"
  [[ -f "$rf/_main/$p" ]] && { echo "$rf/_main/$p"; return; }
  echo "$p"
}
ART="$(resolve "$ARTIFACT")"

sha16() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -c1-16; }

case "$KIND" in
  static_cdn)
    # Immutable content-addressed key: <stem>.<sha16>.<ext> under the CDN prefix.
    base="$(basename "$ART")"; ext="${base##*.}"; stem="${base%.*}"
    key="${DEST%/}/${stem}.$(sha16 "$ART").${ext}"
    if have aws; then
      log "aws s3 cp $ART -> $key (immutable)"
      aws s3 cp "$ART" "$key" --cache-control "public, max-age=31536000, immutable" --no-progress
    else
      log "DRY-RUN (no aws): would upload $ART -> $key"
    fi
    ;;
  site)
    tmp="$(mktemp -d)"; tar -xzf "$ART" -C "$tmp"
    if have aws; then
      log "aws s3 sync (extracted site) -> ${DEST%/}"
      aws s3 sync "$tmp" "${DEST%/}" --delete --no-progress
    else
      log "DRY-RUN (no aws): would sync extracted site -> $DEST"
    fi
    ;;
  oci)
    if have oras; then
      log "oras push $DEST <- $ART"
      oras push "$DEST" "$ART"
    else
      log "DRY-RUN (no oras): would push $ART -> $DEST"
    fi
    ;;
  github_release)
    if have gh; then
      log "gh release upload $TAG (repo $REPO) <- $ART"
      gh release upload "$TAG" "$ART" --repo "$REPO" --clobber
    else
      log "DRY-RUN (no gh): would upload $ART -> $REPO release $TAG (asset ${ASSET:-$(basename "$ART")})"
    fi
    ;;
  *)
    echo "publish_runner: unknown kind '$KIND'" >&2; exit 2 ;;
esac
