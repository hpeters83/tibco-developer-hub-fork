#!/usr/bin/env bash
#
# release-portable.sh — build and publish a DevHub Portable release.
#
# Wraps the three manual steps used previously:
#   1. build the bundle zips (host darwin + linux-x64 via Docker)
#   2. tag the commit (portable-v*)
#   3. gh release create with the zips attached
#
# Windows (win32-x64) cannot be built here — build it on a Windows machine with
# DevHub_Portable/scripts/build-bundled.ps1 and drop the zip into
# DevHub_Portable/dist/ before running this (it will be picked up automatically).
#
# Usage:
#   ./release-portable.sh <version>
#   ./release-portable.sh portable-v1.18.1
#   ./release-portable.sh 1.18.1                 # 'portable-v' prefix added if missing
#
# Options:
#   --repo <owner/repo>   GitHub repo to publish to (default: hpeters83/tibco-developer-hub-fork)
#   --target <branch>     git ref the release tag points at (passed to gh --target)
#   --notes <text>        release notes (default: a sensible summary)
#   --not-latest          mark the release as NOT latest (gh --latest=false)
#   --skip-build          reuse existing zips in DevHub_Portable/dist/ (no rebuild)
#   --skip-linux          build only the host (darwin) target, no Docker
#   --skip-install        reuse existing node_modules during the host build
#   --no-tag              don't create/push a git tag (assume it already exists)
#   --yes                 don't prompt before publishing
#   -h | --help           show this help
#
# Environment:
#   GH_TOKEN / GITHUB_TOKEN   used by `gh` for auth (if not already logged in)
#
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABLE_DIR="$ROOT/DevHub_Portable"
DIST="$PORTABLE_DIR/dist"

REPO="hpeters83/tibco-developer-hub-fork"
TARGET=""
NOTES=""
LATEST=1
DO_BUILD=1
SKIP_LINUX=0
SKIP_INSTALL=0
DO_TAG=1
ASSUME_YES=0
VERSION=""

die() { echo "release-portable: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

show_help() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

# --- parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="${2:?--repo needs a value}"; shift 2 ;;
    --repo=*)      REPO="${1#*=}"; shift ;;
    --target)      TARGET="${2:?--target needs a value}"; shift 2 ;;
    --target=*)    TARGET="${1#*=}"; shift ;;
    --notes)       NOTES="${2:?--notes needs a value}"; shift 2 ;;
    --notes=*)     NOTES="${1#*=}"; shift ;;
    --not-latest)  LATEST=0; shift ;;
    --skip-build)  DO_BUILD=0; shift ;;
    --skip-linux)  SKIP_LINUX=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --no-tag)      DO_TAG=0; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    -h|--help)     show_help; exit 0 ;;
    -*)            die "unknown option '$1' (try --help)" ;;
    *)             [[ -z "$VERSION" ]] && VERSION="$1" || die "unexpected argument '$1'"; shift ;;
  esac
done

[[ -n "$VERSION" ]] || die "version is required, e.g. ./release-portable.sh portable-v1.18.1"
# Normalise: accept '1.18.1', 'v1.18.1' or 'portable-v1.18.1'.
case "$VERSION" in
  portable-v*) ;;
  v*)          VERSION="portable-${VERSION}" ;;
  *)           VERSION="portable-v${VERSION}" ;;
esac
TITLE="DevHub Portable ${VERSION#portable-}"
[[ -n "$NOTES" ]] || NOTES="TechDocs: launcher auto-provisions a local Python venv with mkdocs-techdocs-core on first run. Bundled builds attached below."

have gh || die "the GitHub CLI 'gh' is required (https://cli.github.com/)."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run 'gh auth login' or set GH_TOKEN."

echo "==> Release plan"
echo "    version : $VERSION"
echo "    title   : $TITLE"
echo "    repo    : $REPO"
[[ -n "$TARGET" ]] && echo "    target  : $TARGET"
echo "    latest  : $([[ $LATEST -eq 1 ]] && echo yes || echo no)"
echo "    build   : $([[ $DO_BUILD -eq 1 ]] && echo yes || echo 'no (reuse dist/)')"
echo

# --- 1. build ----------------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "==> [1/3] Building bundles"
  BUILD_ARGS=()
  [[ "$SKIP_INSTALL" -eq 1 ]] && BUILD_ARGS+=(--skip-install)
  [[ "$SKIP_LINUX" -eq 1 ]] && BUILD_ARGS+=(--skip-linux)
  bash "$PORTABLE_DIR/scripts/build-all.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
else
  echo "==> [1/3] Skipping build (--skip-build)"
fi

shopt -s nullglob
ZIPS=("$DIST"/devhub-bundled-*.zip)
shopt -u nullglob
[[ ${#ZIPS[@]} -gt 0 ]] || die "no zips found in $DIST — build first or drop them in."
echo "==> Artifacts to publish:"
for z in "${ZIPS[@]}"; do echo "    $(basename "$z")"; done
echo

# --- confirm ------------------------------------------------------------------
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Tag, push and publish '$VERSION' to $REPO? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted."
fi

# --- 2. tag ------------------------------------------------------------------
if [[ "$DO_TAG" -eq 1 ]]; then
  echo "==> [2/3] Tagging $VERSION"
  if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "    tag $VERSION already exists locally — reusing."
  else
    git tag -a "$VERSION" -m "$TITLE"
  fi
  git push origin "$VERSION"
else
  echo "==> [2/3] Skipping tag (--no-tag)"
fi

# --- 3. publish --------------------------------------------------------------
echo "==> [3/3] Creating GitHub release"
GH_ARGS=(release create "$VERSION" "${ZIPS[@]}" --repo "$REPO" --title "$TITLE" --notes "$NOTES")
[[ -n "$TARGET" ]] && GH_ARGS+=(--target "$TARGET")
if [[ "$LATEST" -eq 1 ]]; then GH_ARGS+=(--latest); else GH_ARGS+=(--latest=false); fi

if gh "${GH_ARGS[@]}"; then
  echo
  echo "==> Done. Released $VERSION to $REPO."
else
  echo
  die "gh release create failed. If the release already exists, upload assets with:
    gh release upload $VERSION ${DIST}/devhub-bundled-*.zip --repo $REPO --clobber"
fi
