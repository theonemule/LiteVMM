#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if ! command -v node >/dev/null 2>&1; then
  echo 'host selector: SKIP (node unavailable)'
  exit 0
fi

node - "$ROOT/www/app.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const sourcePath = process.argv[2];
const source = fs.readFileSync(sourcePath, 'utf8').replace(
  /\n  init\(\);\n\}\)\(\);\s*$/,
  '\n  globalThis.__hostSelectorTestHooks = { buildHostCatalog, hostRouteHash };\n})();\n',
);
const context = { console, globalThis: {} };
vm.runInNewContext(source, context, { filename: sourcePath });
const { buildHostCatalog, hostRouteHash } = context.globalThis.__hostSelectorTestHooks;
const firstId = 'a'.repeat(32);
const secondId = 'b'.repeat(32);
const catalog = buildHostCatalog({ name: 'local-a' }, [
  { node_id: firstId, name: 'paired-a', url: 'https://a.example', api_auth: 'basic' },
  { node_id: secondId, name: 'paired-a', url: 'https://b.example', api_auth: 'basic' },
  { node_id: 'c'.repeat(32), name: 'legacy', url: 'https://legacy.example', api_auth: 're-pair-required' },
  { node_id: 'd'.repeat(32), name: 'no-endpoint', api_auth: 'basic' },
]);
if (catalog.peers.length !== 2) throw new Error('selector included an unusable peer');
if (catalog.peers.some(peer => !peer.label.includes(peer.node_id.slice(0, 12)))) throw new Error('duplicate names were not disambiguated');
if (hostRouteHash('vms', firstId) !== `#vms?peer=${firstId}`) throw new Error('remote route hash is incorrect');
if (hostRouteHash('cluster', firstId) !== `#dashboard?peer=${firstId}`) throw new Error('cluster remote switch must open dashboard');
if (hostRouteHash('cluster') !== '#cluster') throw new Error('local cluster route is incorrect');
NODE

echo 'host selector: PASS'
