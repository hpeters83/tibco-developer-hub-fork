#!/usr/bin/env bash
#
# Build the BUNDLED "DevHub Portable" for the CURRENT host platform.
#
# Uses esbuild to collapse the backend into a single index.js and ships only a
# minimal sidecar node_modules (native modules + a few packages that load on-disk
# assets). Result: ~3k files, so the zip extracts in seconds.
#
# Output: DevHub_Portable/dist/devhub-bundled-<os>-<arch>/ and a matching .zip.
# Native modules are compiled for the host, so this builds only the host platform.
# To build all targets locally, use build-all.sh (host + Linux via Docker); the
# Windows zip is built by running build-bundled.ps1 on a Windows machine.
#
# Usage:
#   DevHub_Portable/scripts/build-bundled.sh [--skip-install] [--no-zip] [--keep-node]
#
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$PORTABLE_DIR/.." && pwd)"
OUT="$PORTABLE_DIR/dist"

SKIP_INSTALL=0
DO_ZIP=1
STRIP_NODE=1
DO_TECHDOCS=0
for arg in "$@"; do
  case "$arg" in
    --skip-install) SKIP_INSTALL=1 ;;
    --no-zip)       DO_ZIP=0 ;;
    --keep-node)    STRIP_NODE=0 ;;
    --techdocs)     DO_TECHDOCS=1 ;;
    *) echo "build-bundled: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

# Standalone-Python series embedded into the techdocs variant (override if needed).
PBS_PYTHON_SERIES="${PBS_PYTHON_SERIES:-3.12}"

# --- detect target os/arch ---------------------------------------------------
case "$(uname -s)" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux" ;;
  *) echo "build-bundled: unsupported OS (use build-bundled.ps1 on Windows)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) echo "build-bundled: unsupported arch" >&2; exit 1 ;;
esac
TARGET="$OS-$ARCH"
BUNDLE="$OUT/devhub-bundled-$TARGET"
NODE_VERSION="$(node -v)"

echo "==> Building DevHub Portable (bundled) for $TARGET (Node $NODE_VERSION)"
cd "$ROOT"

# --- 1. install + build the frontend (root base path) ------------------------
if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  echo "==> yarn install --immutable"
  yarn install --immutable
fi
# The single-process portable serves app + static + /api all at the root path, so
# build the frontend with a root base path (no /tibco/hub). Host/port are injected
# at runtime, so the literal value here only matters for its empty URL *path*.
export APP_CONFIG_app_baseUrl="http://localhost:7007"
export APP_CONFIG_backend_baseUrl="http://localhost:7007"
echo "==> yarn workspace app build (frontend static assets)"
yarn workspace app build

# --- 2. esbuild the backend into a single index.js ---------------------------
echo "==> esbuild backend -> index.js"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
DEVHUB_BUNDLE_OUT="$BUNDLE" node "$SCRIPT_DIR/esbuild-backend.mjs"
[[ -f "$BUNDLE/index.js" ]] || { echo "esbuild did not produce index.js" >&2; exit 1; }

# --- 3. discover the minimal sidecar by tracing a real boot ------------------
echo "==> Tracing runtime module usage (booting the bundle)"
PKG_LIST="$(mktemp)"
DATA_DIR="$(mktemp -d)"
trap 'rm -rf "$DATA_DIR" "$PKG_LIST"' EXIT
DEVHUB_TRACE_BUNDLE="$BUNDLE/index.js" \
DEVHUB_TRACE_OUT="$PKG_LIST" \
DEVHUB_TRACE_EXIT_MS=20000 \
DEVHUB_PORT=7071 \
DEVHUB_DATA_DIR="$DATA_DIR" \
DOC_URL="https://example.com" \
NODE_OPTIONS="--no-node-snapshot" \
  node "$SCRIPT_DIR/trace-requires.cjs" --config "$PORTABLE_DIR/config/app-config.portable.yaml" \
  > "$DATA_DIR/trace.log" 2>&1 || true
if [[ ! -s "$PKG_LIST" ]]; then
  echo "build-bundled: trace produced no package list — see boot log:" >&2
  tail -30 "$DATA_DIR/trace.log" >&2
  exit 1
fi
echo "    $(wc -l < "$PKG_LIST" | tr -d ' ') packages traced"

# --- 4. build the minimal sidecar node_modules -------------------------------
echo "==> Building minimal sidecar node_modules"
node "$SCRIPT_DIR/build-sidecar.cjs" "$ROOT" "$BUNDLE/node_modules" "$PKG_LIST" "$TARGET"
for m in isolated-vm better-sqlite3; do
  [[ -d "$BUNDLE/node_modules/$m" ]] || echo "WARNING: $m missing from sidecar" >&2
done

# --- 5. embed (and strip) the Node runtime -----------------------------------
echo "==> Downloading Node $NODE_VERSION for $TARGET"
NODE_PKG="node-$NODE_VERSION-$OS-$ARCH"
TMP_NODE="$(mktemp -d)"
curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$NODE_PKG.tar.gz" -o "$TMP_NODE/node.tar.gz"
tar xzf "$TMP_NODE/node.tar.gz" -C "$TMP_NODE"
rm -rf "$BUNDLE/node"
mv "$TMP_NODE/$NODE_PKG" "$BUNDLE/node"
rm -rf "$TMP_NODE"
if [[ "$STRIP_NODE" -eq 1 ]]; then
  echo "==> Stripping Node runtime to bin/node (drops npm/corepack/headers/share)"
  # The backend never shells out to npm; only the node binary is needed. ICU is
  # statically linked in official builds, so bin/node is self-sufficient.
  find "$BUNDLE/node" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
  find "$BUNDLE/node/bin" -mindepth 1 ! -name node -exec rm -rf {} +
fi
[[ -x "$BUNDLE/node/bin/node" ]] || { echo "embedded node missing" >&2; exit 1; }

# --- 6. config, launcher, readme ---------------------------------------------
echo "==> Adding config, launcher and README"
cp "$PORTABLE_DIR/config/app-config.portable.yaml" "$BUNDLE/"
cp "$PORTABLE_DIR/launchers/devhub" "$BUNDLE/devhub"
cp "$PORTABLE_DIR/launchers/find-free-port.cjs" "$BUNDLE/find-free-port.cjs"
chmod +x "$BUNDLE/devhub"
mkdir -p "$BUNDLE/data"
# Version stamp shown on launch. For release downloads the installer overwrites this
# with the release tag; a directly-run local build keeps this build marker.
printf 'local build %s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" > "$BUNDLE/.devhub-release"

cat > "$BUNDLE/README.txt" <<EOF
TIBCO Developer Hub — Portable, bundled ($TARGET)

Run:
  ./devhub                      Start on http://localhost:7007
  ./devhub --port 8088          Start on a custom port
  ./devhub --config ./my.yaml   Load extra app-config (repeatable)

The backend is a single index.js and node_modules/ contains only the native modules
and on-disk assets it loads at runtime, so the folder has few files and extracts fast.

Data is stored under ./data and persists across restarts. No Docker/Postgres.
Built with embedded Node $NODE_VERSION.
EOF

# --- 7. zip ------------------------------------------------------------------
if [[ "$DO_ZIP" -eq 1 ]]; then
  echo "==> Zipping"
  ( cd "$OUT" && rm -f "devhub-bundled-$TARGET.zip" && zip -qry "devhub-bundled-$TARGET.zip" "devhub-bundled-$TARGET" )
  echo "==> Wrote $OUT/devhub-bundled-$TARGET.zip"
fi

echo "==> Done: $BUNDLE"
echo "    files: $(find "$BUNDLE" -type f | wc -l | tr -d ' ')"

# --- 8. techdocs variant (optional) ------------------------------------------
# A second, self-contained bundle that embeds a RELOCATABLE standalone Python
# (from astral-sh/python-build-standalone) with mkdocs-techdocs-core pre-installed,
# so TechDocs renders on a bare machine with no host Python and no network. It's a
# copy of the lean bundle plus a ./python runtime and a path-independent ./python-bin/mkdocs
# wrapper (the launcher prefers these when present). Shipped as a separate, larger zip.
embed_standalone_python() {
  local dest="$1" os="$2" arch="$3"
  local triple
  case "$os-$arch" in
    darwin-arm64) triple="aarch64-apple-darwin" ;;
    darwin-x64)   triple="x86_64-apple-darwin" ;;
    linux-x64)    triple="x86_64-unknown-linux-gnu" ;;
    linux-arm64)  triple="aarch64-unknown-linux-gnu" ;;
    *) echo "build-bundled: no standalone-python build for $os-$arch" >&2; return 1 ;;
  esac

  echo "==> Resolving standalone Python ($PBS_PYTHON_SERIES, $triple)"
  local hdr=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
  local url
  url="$(curl -fsSL ${hdr[@]+"${hdr[@]}"} \
        "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest" \
        | grep -o '"browser_download_url": *"[^"]*"' \
        | sed -E 's/.*"(https[^"]+)".*/\1/' \
        | grep -E "cpython-${PBS_PYTHON_SERIES//./\\.}\.[0-9].*-${triple}-install_only\.tar\.gz$" \
        | head -1)"
  [[ -n "$url" ]] || { echo "build-bundled: could not resolve a standalone Python for $triple (series $PBS_PYTHON_SERIES)" >&2; return 1; }

  echo "==> Downloading $(basename "$url")"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/python.tar.gz"
  tar xzf "$tmp/python.tar.gz" -C "$tmp"          # extracts to $tmp/python
  rm -rf "$dest/python"
  mv "$tmp/python" "$dest/python"
  rm -rf "$tmp"

  echo "==> Installing mkdocs-techdocs-core into embedded Python"
  "$dest/python/bin/python3" -m ensurepip --upgrade >/dev/null 2>&1 || true
  "$dest/python/bin/python3" -m pip install --quiet --disable-pip-version-check \
    --upgrade pip mkdocs-techdocs-core

  # Path-independent wrapper: Backstage spawns the literal `mkdocs` binary, so we
  # expose one that calls the embedded interpreter via `-m mkdocs` (no absolute
  # shebang, survives being unzipped to any path).
  mkdir -p "$dest/python-bin"
  cat > "$dest/python-bin/mkdocs" <<'WRAP'
#!/bin/sh
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$DIR/../python/bin/python3" -m mkdocs "$@"
WRAP
  chmod +x "$dest/python-bin/mkdocs"
  "$dest/python-bin/mkdocs" --version >/dev/null || { echo "build-bundled: embedded mkdocs failed to run" >&2; return 1; }
}

if [[ "$DO_TECHDOCS" -eq 1 ]]; then
  echo "==> Building self-contained TechDocs variant (devhub-bundled-techdocs-$TARGET)"
  TD_BUNDLE="$OUT/devhub-bundled-techdocs-$TARGET"
  rm -rf "$TD_BUNDLE"
  cp -R "$BUNDLE" "$TD_BUNDLE"
  embed_standalone_python "$TD_BUNDLE" "$OS" "$ARCH"
  # Note the self-contained nature in the bundled README.
  cat >> "$TD_BUNDLE/README.txt" <<EOF

This is the self-contained TechDocs build: it embeds a standalone Python runtime
with mkdocs (under ./python) so generating documentation works with no host Python
and no network access. It is larger than the standard bundle for that reason.
EOF
  if [[ "$DO_ZIP" -eq 1 ]]; then
    echo "==> Zipping techdocs variant"
    ( cd "$OUT" && rm -f "devhub-bundled-techdocs-$TARGET.zip" \
        && zip -qry "devhub-bundled-techdocs-$TARGET.zip" "devhub-bundled-techdocs-$TARGET" )
    echo "==> Wrote $OUT/devhub-bundled-techdocs-$TARGET.zip"
  fi
  echo "==> Done: $TD_BUNDLE"
  echo "    files: $(find "$TD_BUNDLE" -type f | wc -l | tr -d ' ')"
fi
