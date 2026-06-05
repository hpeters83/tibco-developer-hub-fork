#!/usr/bin/env bash
#
# Build an experimental SINGLE-EXECUTABLE DevHub for the current host platform,
# using Node's built-in SEA (Single Executable Applications) feature.
#
# The result is one `devhub` binary (the Node runtime + the launcher baked in)
# plus sidecar node_modules/ and packages/ — the native modules (isolated-vm,
# better-sqlite3) and Backstage's dynamically-loaded plugins + frontend dist
# cannot be embedded inside the binary, so they sit next to it.
#
# Reuses the folder bundle produced by build-portable.sh as the source of
# node_modules / packages / config, so run that first.
#
# Usage:
#   DevHub_Portable/scripts/build-single-exe.sh [--no-zip]
#
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTABLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_ROOT="$PORTABLE_DIR/dist"

DO_ZIP=1
for arg in "$@"; do
  case "$arg" in
    --no-zip) DO_ZIP=0 ;;
    *) echo "build-single-exe: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

# --- target detection --------------------------------------------------------
case "$(uname -s)" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux" ;;
  *) echo "build-single-exe: unsupported OS (use Windows tooling separately)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) echo "build-single-exe: unsupported arch" >&2; exit 1 ;;
esac
TARGET="$OS-$ARCH"

SRC_BUNDLE="$OUT_ROOT/devhub-$TARGET"
OUT="$OUT_ROOT/single-exe-$TARGET"
FUSE="NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2"

if [[ ! -d "$SRC_BUNDLE/node_modules" || ! -d "$SRC_BUNDLE/packages/backend" ]]; then
  echo "build-single-exe: folder bundle not found at $SRC_BUNDLE" >&2
  echo "Run DevHub_Portable/scripts/build-portable.sh first." >&2
  exit 1
fi

echo "==> Building single executable for $TARGET"
rm -rf "$OUT"
mkdir -p "$OUT/.sea"

# --- 1. SEA blob -------------------------------------------------------------
cp "$SCRIPT_DIR/sea-entry.js" "$OUT/.sea/sea-entry.js"
cat > "$OUT/.sea/sea-config.json" <<EOF
{
  "main": "sea-entry.js",
  "output": "sea-prep.blob",
  "disableExperimentalSEAWarning": true,
  "useSnapshot": false,
  "useCodeCache": false
}
EOF
echo "==> Generating SEA blob"
( cd "$OUT/.sea" && node --experimental-sea-config sea-config.json )

# --- 2. copy the Node binary and inject the blob -----------------------------
echo "==> Creating devhub binary from embedded Node runtime"
cp "$SRC_BUNDLE/node/bin/node" "$OUT/devhub"
chmod +w "$OUT/devhub"

POSTJECT_ARGS=("$OUT/devhub" NODE_SEA_BLOB "$OUT/.sea/sea-prep.blob" --sentinel-fuse "$FUSE")
if [[ "$OS" == "darwin" ]]; then
  codesign --remove-signature "$OUT/devhub" || true
  POSTJECT_ARGS+=(--macho-segment-name NODE_SEA)
fi

echo "==> Injecting blob with postject"
npx --yes postject "${POSTJECT_ARGS[@]}"

if [[ "$OS" == "darwin" ]]; then
  codesign --sign - "$OUT/devhub"
fi
chmod +x "$OUT/devhub"

# --- 3. sidecars -------------------------------------------------------------
echo "==> Copying sidecar runtime (node_modules, packages, config)"
cp -R "$SRC_BUNDLE/node_modules" "$OUT/node_modules"
cp -R "$SRC_BUNDLE/packages" "$OUT/packages"
[[ -d "$SRC_BUNDLE/plugins" ]] && cp -R "$SRC_BUNDLE/plugins" "$OUT/plugins"
[[ -f "$SRC_BUNDLE/package.json" ]] && cp "$SRC_BUNDLE/package.json" "$OUT/"
[[ -f "$SRC_BUNDLE/yarn.lock" ]] && cp "$SRC_BUNDLE/yarn.lock" "$OUT/"
cp "$PORTABLE_DIR/config/app-config.portable.yaml" "$OUT/"
mkdir -p "$OUT/data"
rm -rf "$OUT/.sea"

cat > "$OUT/README.txt" <<EOF
TIBCO Developer Hub — Single Executable ($TARGET)

Run:
  ./devhub                      Start on http://localhost:7007
  ./devhub --port 8088          Start on a custom port
  ./devhub --config ./my.yaml   Load extra app-config (repeatable)

This folder is a single 'devhub' executable (Node runtime + launcher baked in)
plus the node_modules/ and packages/ it loads at runtime. The native modules and
Backstage's dynamically-loaded plugins/frontend cannot be embedded inside the
binary, so they must stay alongside it. Keep the folder together.

Data is stored under ./data and persists across restarts.
EOF

# --- 4. zip ------------------------------------------------------------------
if [[ "$DO_ZIP" -eq 1 ]]; then
  echo "==> Zipping"
  ( cd "$OUT_ROOT" && rm -f "single-exe-$TARGET.zip" && zip -qry "single-exe-$TARGET.zip" "single-exe-$TARGET" )
  echo "==> Wrote $OUT_ROOT/single-exe-$TARGET.zip"
fi

echo "==> Done: $OUT"
echo "    Binary: $OUT/devhub"
