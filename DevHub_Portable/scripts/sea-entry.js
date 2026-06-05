'use strict';
/*
 * Entry point baked into the DevHub single-executable via Node SEA.
 *
 * It reproduces the `devhub` launcher: parses --port / --config, sets up the
 * runtime environment, and starts the Backstage backend bundle. node_modules and
 * packages/ live next to the executable as sidecars (they cannot be embedded:
 * isolated-vm / better-sqlite3 are native, and Backstage loads plugins + the
 * frontend dist from the real filesystem).
 */
const path = require('node:path');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { createRequire } = require('node:module');

// Folder the executable lives in — sidecar node_modules / packages / config.
const exeDir = path.dirname(process.execPath);

// SEA argv is [resolvedExecPath, launchPath, ...userArgs] — the same shape as a
// normal `node script.js ...` run — so user args start at index 2.
const userArgs = process.argv.slice(2);

// isolated-vm needs --no-node-snapshot. SEA binaries don't take node CLI flags
// directly, so on first launch we re-exec ourselves once with it in NODE_OPTIONS
// (proven to be accepted there by the folder launcher).
if (process.env.DEVHUB_SEA_REEXEC !== '1') {
  const env = { ...process.env, DEVHUB_SEA_REEXEC: '1' };
  env.NODE_OPTIONS = `${env.NODE_OPTIONS || ''} --no-node-snapshot`.trim();
  const res = spawnSync(process.execPath, userArgs, {
    stdio: 'inherit',
    env,
  });
  process.exit(res.status === null ? 1 : res.status);
}

// --- argument parsing --------------------------------------------------------
let port = process.env.DEVHUB_PORT || '7007';
const extraConfigs = [];
const args = userArgs;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--port') port = args[++i];
  else if (a.startsWith('--port=')) port = a.slice('--port='.length);
  else if (a === '--config') extraConfigs.push('--config', args[++i]);
  else if (a.startsWith('--config=')) extraConfigs.push('--config', a.slice('--config='.length));
  else if (a === '-h' || a === '--help') {
    console.log('Usage: devhub [--port N] [--config path ...]');
    process.exit(0);
  } else {
    console.error(`devhub: unknown argument '${a}' (try --help)`);
    process.exit(1);
  }
}

// --- runtime environment -----------------------------------------------------
process.env.DEVHUB_PORT = port;
process.env.DEVHUB_DATA_DIR = process.env.DEVHUB_DATA_DIR || path.join(exeDir, 'data');
process.env.NODE_ENV = process.env.NODE_ENV || 'production';
process.env.GIT_PYTHON_REFRESH = process.env.GIT_PYTHON_REFRESH || 'quiet';
process.env.GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';
process.env.DOC_URL =
  process.env.DOC_URL ||
  'https://docs.tibco.com/go/platform-cp/latest/doc/html#cshid=developer_hub_overview';

fs.mkdirSync(process.env.DEVHUB_DATA_DIR, { recursive: true });

// Resolve modules from the sidecar layout next to the executable.
process.chdir(exeDir);
const requireFromExe = createRequire(path.join(exeDir, 'devhub-sea.js'));
const backendEntry = path.join(exeDir, 'packages', 'backend');
const portableConfig = path.join(exeDir, 'app-config.portable.yaml');

// The backend reads process.argv for its --config flags, exactly like
// `node packages/backend --config ...`.
process.argv = [
  process.execPath,
  backendEntry,
  '--config',
  portableConfig,
  ...extraConfigs,
];

console.log('Starting TIBCO Developer Hub (portable, single executable)');
console.log(`  URL:  http://localhost:${port}`);
console.log(`  Data: ${process.env.DEVHUB_DATA_DIR}`);
console.log('');

requireFromExe(backendEntry);
