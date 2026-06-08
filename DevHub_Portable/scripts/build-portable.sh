#!/usr/bin/env bash
#
# Build a self-contained "DevHub Portable" bundle for the CURRENT host platform.
#
# Produces DevHub_Portable/dist/devhub-<os>-<arch>/ (a runnable folder) and a
# matching .zip. Native modules (isolated-vm, better-sqlite3) are compiled for the
# host, so this script can only build the platform it runs on — the other targets
# are produced by the GitHub Actions matrix (.github/workflows/devhub-portable.yml).
#
# Usage:
#   DevHub_Portable/scripts/build-portable.sh [--skip-install] [--no-zip]
#
set -euo pipefail

# --- locate paths ------------------------------------------------------------
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$PORTABLE_DIR/.." && pwd)"
OUT="$PORTABLE_DIR/dist"

SKIP_INSTALL=0
DO_ZIP=1
for arg in "$@"; do
  case "$arg" in
    --skip-install) SKIP_INSTALL=1 ;;
    --no-zip)       DO_ZIP=0 ;;
    *) echo "build-portable: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

# --- detect target os/arch ---------------------------------------------------
UNAME_S="$(uname -s)"
case "$UNAME_S" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux" ;;
  *) echo "build-portable: unsupported OS '$UNAME_S' (use build-portable.ps1 on Windows)" >&2; exit 1 ;;
esac
UNAME_M="$(uname -m)"
case "$UNAME_M" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) echo "build-portable: unsupported arch '$UNAME_M'" >&2; exit 1 ;;
esac
TARGET="$OS-$ARCH"
BUNDLE="$OUT/devhub-$TARGET"

# Embed the SAME Node version that compiles the native modules, so the native
# module ABI matches the bundled runtime.
NODE_VERSION="$(node -v)"   # e.g. v24.15.0

echo "==> Building DevHub Portable for $TARGET (Node $NODE_VERSION)"

# --- 1. build the backend bundle (embeds the built frontend) -----------------
cd "$ROOT"
if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "==> yarn install --immutable"
  yarn install --immutable
fi
echo "==> yarn workspace backend build"
# Build the frontend with a ROOT base path (no /tibco/hub). In a single-process
# portable build there is no ingress to strip the prefix, so the app, its static
# assets, and the /api routes must all live at the root path. Backstage bakes the
# frontend public path from app.baseUrl at build time; override it here. (Host/port
# are still injected at runtime, so the literal localhost:7007 value is irrelevant —
# only the empty URL *path* matters.)
export APP_CONFIG_app_baseUrl="http://localhost:7007"
export APP_CONFIG_backend_baseUrl="http://localhost:7007"
yarn workspace backend build

BUNDLE_TGZ="$ROOT/packages/backend/dist/bundle.tar.gz"
SKELETON_TGZ="$ROOT/packages/backend/dist/skeleton.tar.gz"
[[ -f "$BUNDLE_TGZ" ]]   || { echo "missing $BUNDLE_TGZ" >&2; exit 1; }
[[ -f "$SKELETON_TGZ" ]] || { echo "missing $SKELETON_TGZ" >&2; exit 1; }

# --- 2. assemble bundle root -------------------------------------------------
echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
tar xzf "$BUNDLE_TGZ" -C "$BUNDLE"
[[ -d "$BUNDLE/packages/backend" ]] || { echo "bundle missing packages/backend" >&2; exit 1; }

# --- 3. production node_modules (compiles native modules for the host) -------
echo "==> Installing production dependencies (this compiles isolated-vm / better-sqlite3)"
PROD="$(mktemp -d)"
trap 'rm -rf "$PROD"' EXIT
tar xzf "$SKELETON_TGZ" -C "$PROD"
cp "$ROOT/package.json" "$ROOT/yarn.lock" "$ROOT/.yarnrc.yml" "$PROD/"
[[ -f "$ROOT/backstage.json" ]] && cp "$ROOT/backstage.json" "$PROD/"
# Yarn release binary + patches referenced by .yarnrc.yml / resolutions.
mkdir -p "$PROD/.yarn"
cp -R "$ROOT/.yarn/releases" "$PROD/.yarn/releases"
[[ -d "$ROOT/.yarn/patches" ]] && cp -R "$ROOT/.yarn/patches" "$PROD/.yarn/patches"
[[ -d "$ROOT/.yarn/plugins" ]] && cp -R "$ROOT/.yarn/plugins" "$PROD/.yarn/plugins"
(
  cd "$PROD"
  yarn workspaces focus --all --production
)
cp -R "$PROD/node_modules" "$BUNDLE/node_modules"

# sanity: native modules present
for m in isolated-vm better-sqlite3; do
  [[ -d "$BUNDLE/node_modules/$m" ]] || { echo "WARNING: $m not found in node_modules" >&2; }
done

# The in-repo workspace packages (app, @internal/*) are symlinked into node_modules.
# Replace those links with real copies sourced from the bundle's own plugins/packages
# so the bundle is fully self-contained — relative symlinks survive macOS/Linux but
# Windows junctions are absolute and break once the bundle is moved/zipped/extracted.
echo "==> Materializing workspace packages into node_modules (self-contained)"
for d in "$BUNDLE"/plugins/* "$BUNDLE"/packages/*; do
  [[ -f "$d/package.json" ]] || continue
  pkg_name="$(node -p "require('$d/package.json').name" 2>/dev/null || true)"
  [[ -n "$pkg_name" && "$pkg_name" != "undefined" ]] || continue
  dest="$BUNDLE/node_modules/$pkg_name"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$d" "$dest"
done

# --- 4. embed the Node runtime ----------------------------------------------
echo "==> Downloading Node $NODE_VERSION for $TARGET"
NODE_PKG="node-$NODE_VERSION-$OS-$ARCH"
NODE_URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_PKG.tar.gz"
TMP_NODE="$(mktemp -d)"
curl -fsSL "$NODE_URL" -o "$TMP_NODE/node.tar.gz"
tar xzf "$TMP_NODE/node.tar.gz" -C "$TMP_NODE"
rm -rf "$BUNDLE/node"
mv "$TMP_NODE/$NODE_PKG" "$BUNDLE/node"
rm -rf "$TMP_NODE"
[[ -x "$BUNDLE/node/bin/node" ]] || { echo "embedded node missing" >&2; exit 1; }

# --- 5. config, launcher, readme --------------------------------------------
echo "==> Adding config, launcher and README"
cp "$PORTABLE_DIR/config/app-config.portable.yaml" "$BUNDLE/"
cp "$PORTABLE_DIR/launchers/devhub" "$BUNDLE/devhub"
chmod +x "$BUNDLE/devhub"
mkdir -p "$BUNDLE/data"

cat > "$BUNDLE/README.txt" <<EOF
TIBCO Developer Hub — Portable ($TARGET)

Run:
  ./devhub                      Start on http://localhost:7007
  ./devhub --port 8088          Start on a custom port
  ./devhub --config ./my.yaml   Load extra app-config (repeatable; e.g. catalog.locations)

Data (SQLite + scaffolder workspace) is stored under ./data and persists across
restarts. Delete ./data to reset. No Docker or Postgres required.

Optional: set GITHUB_TOKEN in your environment before launching to enable
GitHub-backed features. TechDocs page rendering needs Python 3 + mkdocs-techdocs-core
on PATH (not bundled); the app starts fine without it.

Built with embedded Node $NODE_VERSION.
EOF

# --- 6. zip ------------------------------------------------------------------
if [[ "$DO_ZIP" -eq 1 ]]; then
  echo "==> Zipping"
  ( cd "$OUT" && rm -f "devhub-$TARGET.zip" && zip -qry "devhub-$TARGET.zip" "devhub-$TARGET" )
  echo "==> Wrote $OUT/devhub-$TARGET.zip"
fi

echo "==> Done: $BUNDLE"
