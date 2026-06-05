# DevHub Portable

A self-contained build of the TIBCO® Developer Hub that runs the **frontend and
backend in a single process**, with **no Docker and no Postgres** required. Point it
at your own catalog YAMLs and pick a port from the command line.

This works because in production TIBCO Developer Hub already serves the UI and the API
from one backend process (the `@backstage/plugin-app-backend` plugin) on a single port.
The portable build packages that backend together with an embedded Node runtime, its
production dependencies (including the compiled native modules), and a launcher.

## Quick start — one command

The bootstrap script auto-detects your OS/arch, downloads the matching bundle from the
GitHub release, extracts it into the **current folder** (`./devhub-<os>-<arch>/`), and
starts the hub. Re-running just relaunches the extracted bundle, so it doubles as the
"run" command. (Override the location with `DEVHUB_DIR`.)

```bash
# macOS / Linux — starts on http://localhost:7007
curl -fsSL https://raw.githubusercontent.com/hpeters83/tibco-developer-hub-fork/dev_hub_portable_poc/DevHub_Portable/install.sh | bash

# pass args through after `--` (port, extra config, …)
curl -fsSL https://raw.githubusercontent.com/hpeters83/tibco-developer-hub-fork/dev_hub_portable_poc/DevHub_Portable/install.sh | bash -s -- --port 8088 --config ./my.yaml
```

```powershell
# Windows (PowerShell) — download then run
irm https://raw.githubusercontent.com/hpeters83/tibco-developer-hub-fork/dev_hub_portable_poc/DevHub_Portable/install.ps1 -OutFile $env:TEMP\devhub-install.ps1
& $env:TEMP\devhub-install.ps1 -Port 8088 -Config .\my.yaml
```

Pin a specific release or point at a custom asset with env vars (see the top of
`install.sh`): `DEVHUB_VERSION=portable-v1.0.0`, `DEVHUB_REPO=owner/repo`,
`DEVHUB_URL=<zip url>`, `DEVHUB_DIR=<cache dir>`. Requires `curl` and `unzip`.

> Releases are published by the CI workflow when you push a `portable-v*` tag. Until a
> release exists, use the manual download below or set `DEVHUB_URL`.

## Running a bundle (manual download)

Download/extract a `devhub-<os>-<arch>.zip` and run the launcher from inside it:

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
| `--port <n>` | `7007` | Port the hub listens on (UI + API). URL is `http://localhost:<n>`. |
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

Native modules (`isolated-vm`, `better-sqlite3`) are compiled C++ and **cannot be
cross-compiled**, so each OS/arch must be built on its own platform.

### Locally (current platform only)

Requires Node 22/24, Yarn 4.4.1 (`corepack enable`), and a C++ toolchain + Python 3.

```bash
DevHub_Portable/scripts/build-portable.sh          # macOS / Linux
DevHub_Portable/scripts/build-portable.ps1         # Windows (PowerShell)
```

Output: `DevHub_Portable/dist/devhub-<os>-<arch>/` plus a matching `.zip`. The embedded
Node runtime matches your host's Node version (so the compiled native modules' ABI
matches).

### All platforms (CI)

`.github/workflows/devhub-portable.yml` builds all four targets on a runner matrix
(macOS arm64 + x64, Linux x64, Windows x64). Trigger it manually
("Run workflow") or push a tag like `portable-v1.0.0` to also attach the zips to a
GitHub release. Artifacts are named `devhub-<target>`.

## Single-executable variant (experimental)

`scripts/build-single-exe.sh` wraps the folder bundle into one `devhub` executable
using Node's built-in [SEA](https://nodejs.org/api/single-executable-applications.html)
(the Node runtime + launcher are baked into the binary, and `--no-node-snapshot` is
applied automatically). Run `build-portable.sh` first, then:

```bash
DevHub_Portable/scripts/build-single-exe.sh        # macOS / Linux
```

Output: `dist/single-exe-<target>/` (the `devhub` binary + sidecar `node_modules/`
and `packages/`) plus a `.zip`. Usage is identical (`./devhub --port … --config …`).

**Caveat:** it is *not* a single file. The native modules (`isolated-vm`,
`better-sqlite3`) and Backstage's dynamically-loaded plugins + frontend `dist` cannot
be embedded inside a binary, so `node_modules/` and `packages/` must travel alongside
it — keep the folder together. The win over the folder bundle is one self-contained
executable instead of a separate Node runtime + shell/batch launcher.

## How it's assembled

The build mirrors the production `Dockerfile`:

1. `yarn workspace backend build` → produces `bundle.tar.gz` (backend + embedded
   frontend) and `skeleton.tar.gz` (workspace `package.json`s).
2. Extract `bundle.tar.gz` into the bundle root.
3. From `skeleton.tar.gz` + root `yarn.lock`/`.yarn`, run
   `yarn workspaces focus --all --production` to get a clean production `node_modules`
   (this compiles the native modules for the host).
4. Download the matching Node runtime from `nodejs.org` into `node/`.
5. Add `app-config.portable.yaml`, the launcher, and `data/`.
6. Zip it.
