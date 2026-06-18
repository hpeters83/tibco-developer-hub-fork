# DevHub Portable

A self-contained build of the TIBCO® Developer Hub that runs the **frontend and
backend in a single process**, with **no Docker and no Postgres** required. Point it
at your own catalog YAMLs and pick a port from the command line.

This works because in production TIBCO Developer Hub already serves the UI and the API
from one backend process (the `@backstage/plugin-app-backend` plugin) on a single port.
The portable build bundles that backend into a single `index.js` (via esbuild) plus a
minimal `node_modules` (just the native modules and on-disk assets it loads at runtime),
an embedded Node runtime, and a launcher. The result is ~3,000 files, so the zip
extracts in seconds.

## Quick start — one command

The bootstrap script auto-detects your OS/arch, downloads the matching bundle from the
GitHub release, extracts it into the **current folder** (`./devhub-bundled-<os>-<arch>/`),
and starts the hub. Re-running just relaunches the extracted bundle, so it doubles as the
"run" command. (Override the location with `DEVHUB_DIR`.)

```bash
# macOS / Linux — starts on http://localhost:7007
curl -fsSL https://raw.githubusercontent.com/hpeters83/tibco-developer-hub-fork/dev_hub_portable/DevHub_Portable/install.sh | bash

# pass args through after `--` (port, extra config, …)
curl -fsSL https://raw.githubusercontent.com/hpeters83/tibco-developer-hub-fork/dev_hub_portable/DevHub_Portable/install.sh | bash -s -- --port 8088 --config ./my.yaml
```

```powershell
# Windows (PowerShell) — download, then run with the execution policy bypassed
# (downloaded .ps1 files are blocked by default). Run the two lines as-is; quote the
# path and DO NOT join them with `&` (that's the call operator, not a separator).
irm https://raw.githubusercontent.com/hpeters83/tibco-developer-hub-fork/dev_hub_portable/DevHub_Portable/install.ps1 -OutFile "$env:TEMP\devhub-install.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\devhub-install.ps1" -Port 8088
```

Add `-Config .\my.yaml` to the second line only if that file exists.

Pin a specific release or point at a custom asset with env vars (see the top of
`install.sh`): `DEVHUB_VERSION=portable-v1.0.0`, `DEVHUB_REPO=owner/repo`,
`DEVHUB_URL=<zip url>`, `DEVHUB_DIR=<cache dir>`. Requires `curl` and `unzip`.

> Releases are built locally and published manually (see [Building](#building)). Until a
> release exists, use the manual download below or set `DEVHUB_URL`.

## Running a bundle (manual download)

Download/extract a `devhub-bundled-<os>-<arch>.zip` and run the launcher from inside it:

```bash
# macOS / Linux
./devhub                       # http://localhost:7007
./devhub --port 8088           # custom port
./devhub --config ./my.yaml    # load extra app-config (repeatable)
```

```bat
:: Windows
devhub.cmd
devhub.cmd --port 8088
devhub.cmd --config .\my.yaml
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--port <n>` | `7007` | Port the hub listens on (UI + API). URL is `http://localhost:<n>`. If the default `7007` is busy, the launcher automatically picks the next free port and prints it. |
| `--config <path>` | — | Extra app-config layered on top of the built-in portable config. Repeatable. Use it to add `catalog.locations`, integrations, auth, etc. |

### Loading your own catalog YAMLs

Create a small config file and pass it with `--config`:

```yaml
# my.yaml
catalog:
  locations:
    - type: file
      target: /absolute/path/to/my-component.yaml
    - type: url
      target: https://github.com/acme/repo/blob/main/catalog-info.yaml
```

```bash
./devhub --config ./my.yaml
```

### Data & persistence

State (a SQLite database per plugin, plus the scaffolder workspace) is stored under
`./data` next to the launcher and **persists across restarts**. Delete `./data` to
reset. Override the location with the `DEVHUB_DATA_DIR` environment variable.

### Notes / limitations

- Served at the **root path** (`http://localhost:<port>/`), unlike the production
  deployment which sits behind an ingress at `/tibco/hub`. Only host/port are dynamic
  at runtime (the base path is baked at build time). Auth defaults to **guest** sign-in.
- **TechDocs** page rendering needs Python 3 + `mkdocs-techdocs-core` on `PATH` (not
  bundled). The hub starts fine without it; only opening a docs page would fail.
- Set `GITHUB_TOKEN` in your environment before launching to enable GitHub-backed
  features (catalog imports, scaffolder publish, etc.).

## Building

Native modules (`isolated-vm`, `better-sqlite3`) are compiled C++ and the build boots the
bundle to discover its sidecar, so **each OS/arch must be built on its own platform** —
there is no cross-compiling.

Prerequisites: Node 22/24, Yarn (`corepack enable`), a C++ toolchain + Python 3, and
Docker (for the Linux build).

### Build all targets locally

From a Mac, one command builds the host (macOS arm64) and the Linux x64 zip (in a Docker
container):

```bash
DevHub_Portable/scripts/build-all.sh
#   --skip-install   reuse existing node_modules for the host build
#   --skip-linux     host target only (no Docker)
```

The Linux build runs inside `node:24` with `--platform linux/amd64`; on Apple Silicon that
uses emulation, so it's slower (and needs Docker Desktop running). Output lands in
`DevHub_Portable/dist/devhub-bundled-<os>-<arch>.zip`.

**Windows** can't be built on macOS/Docker (no Windows containers). On a Windows machine
with Node, Yarn (`corepack`), MSVC C++ Build Tools + Python 3:

```powershell
DevHub_Portable\scripts\build-bundled.ps1
```

Then copy `devhub-bundled-win32-x64.zip` next to the other zips in `DevHub_Portable/dist/`.

To build a single target only, call `build-bundled.sh` (host) / `build-bundled.ps1`
(Windows) directly.

### Publish a release (manual)

Upload the zips to a GitHub release; the installers (`install.sh` / `install.ps1`, default
`DEVHUB_REPO`) download from there.

```bash
# gh CLI (brew install gh && gh auth login)
gh release create portable-v1.0.0 DevHub_Portable/dist/devhub-bundled-*.zip \
  --repo hpeters83/tibco-developer-hub-fork \
  --title "DevHub Portable v1.0.0" \
  --notes "Bundled builds: macOS arm64, Linux x64, Windows x64"
```

Or via the web UI: **Releases → Draft a new release →** create tag `portable-v1.0.0` →
drag the zips in → **Publish**.

## How it's assembled

1. `yarn workspace app build` → builds the frontend static assets with a root base path.
2. **esbuild** bundles `packages/backend/src/index.ts` into a single `index.js`, marking
   native modules and a few packages that load their own on-disk assets as external.
3. A trace boot (`trace-requires.cjs`) records exactly which packages the bundle loads at
   runtime; `build-sidecar.cjs` copies just those into a minimal `node_modules` (native
   modules whole, the `@backstage/*` backend plugins reduced to `package.json` +
   `migrations/`), and prunes foreign-platform prebuilds.
4. Download the matching Node runtime from `nodejs.org` into `node/`, stripped to just the
   binary.
5. Add `app-config.portable.yaml`, the launcher (+ `find-free-port.cjs`), and `data/`.
6. Zip it.
