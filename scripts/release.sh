#!/usr/bin/env bash
# Build + push a service image to the Scaleway registry with the project's
# standard tag scheme. Same script in CI and locally — tags are derived from git.
#
# Tag scheme (see infra.lux/README.md):
#   git tag v1.2.0   -> <image>:1.2.0          + <image>:latest
#   merge to master  -> <image>:1.2.0-5-g<sha> + <image>:edge      (git describe)
#   dispatch/branch  -> <image>:<branch>-<sha> [+ <image>:<postfix>]   (never latest/edge)
#
# Usage (run from the service repo root, where the Dockerfile lives):
#   IMAGE=server-encoder bash /path/to/infra.lux/scripts/release.sh [--postfix rc.1] [--push]
#
# Env:
#   IMAGE        required   image name, e.g. server-encoder
#   REGISTRY     rg.fr-par.scw.cloud      registry host
#   NAMESPACE    upskiller                registry namespace
#   PLATFORM     linux/amd64              build platform (Modal/Scaleway are amd64)
#   DOCKERFILE   Dockerfile               path to the Dockerfile
#   CONTEXT      .                        build context
# Flags:
#   --postfix X  extra immutable tag (dispatch builds only)
#   --push       actually push (default: build + print the tags it WOULD push)
set -euo pipefail

REGISTRY="${REGISTRY:-rg.fr-par.scw.cloud}"
NAMESPACE="${NAMESPACE:-upskiller}"
PLATFORM="${PLATFORM:-linux/amd64}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
CONTEXT="${CONTEXT:-.}"
: "${IMAGE:?set IMAGE (e.g. server-encoder)}"

POSTFIX=""
DO_PUSH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --postfix) POSTFIX="$2"; shift 2 ;;
    --push)    DO_PUSH=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

REPO="${REGISTRY}/${NAMESPACE}/${IMAGE}"
SHA="$(git rev-parse --short HEAD)"

# ── Derive context (CI sets GITHUB_*; fall back to local git state) ───────────
# event:       workflow_dispatch / push / "" locally — forces the dispatch path
# ref_tag:     refs/tags/v1.2.0 in CI, or `git describe --exact-match` locally
# branch:      current branch name
event="${GITHUB_EVENT_NAME:-}"
ref_tag=""
branch=""
if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  ref_tag="${GITHUB_REF#refs/tags/}"
  branch="${GITHUB_REF_NAME:-}"
elif [[ -n "${GITHUB_REF_NAME:-}" ]]; then
  branch="${GITHUB_REF_NAME}"
else
  ref_tag="$(git describe --exact-match --tags 2>/dev/null || true)"
  branch="$(git rev-parse --abbrev-ref HEAD)"
fi

sanitize() { echo "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'; }

declare -a TAGS=()
if [[ "$event" == "workflow_dispatch" ]]; then
  # Manual build: branch-sha, never latest/edge (even when dispatched on master).
  TAGS+=("$(sanitize "${branch:-detached}")-${SHA}")
  [[ -n "$POSTFIX" ]] && TAGS+=("$(sanitize "$POSTFIX")")
elif [[ -n "$ref_tag" ]]; then
  # Release: strip a leading 'v'. Immutable semver + moving latest.
  semver="${ref_tag#v}"
  TAGS+=("$semver" "latest")
elif [[ "$branch" == "master" || "$branch" == "main" ]]; then
  # Master tip: git describe gives 1.2.0-5-g<sha> (or just <sha> with no tags yet).
  # Strip a leading 'v' so it matches release tags (1.2.0, not v1.2.0).
  described="$(git describe --tags --always 2>/dev/null || echo "$SHA")"
  TAGS+=("$(sanitize "${described#v}")" "edge")
else
  # Feature branch (local or push): branch-sha, never latest/edge.
  TAGS+=("$(sanitize "${branch:-detached}")-${SHA}")
  [[ -n "$POSTFIX" ]] && TAGS+=("$(sanitize "$POSTFIX")")
fi

echo "Image:    ${REPO}"
echo "Platform: ${PLATFORM}"
echo "Tags:     ${TAGS[*]}"

# ── Build (multi-tag, single build) ──────────────────────────────────────────
tag_args=()
for t in "${TAGS[@]}"; do tag_args+=(-t "${REPO}:${t}"); done

build_args=(
  --platform "$PLATFORM"
  --label "org.opencontainers.image.revision=${SHA}"
  --label "org.opencontainers.image.source=$(git config --get remote.origin.url 2>/dev/null || echo unknown)"
  -f "$DOCKERFILE"
  "${tag_args[@]}"
)

if [[ "$DO_PUSH" == true ]]; then
  docker buildx build "${build_args[@]}" --push "$CONTEXT"
  echo "Pushed: ${TAGS[*]}"
else
  docker buildx build "${build_args[@]}" --load "$CONTEXT"
  echo "Built locally (not pushed). Re-run with --push to publish."
fi
