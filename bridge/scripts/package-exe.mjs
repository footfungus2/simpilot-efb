// Builds the single-file "SimPilot Bridge" app for this platform (CI runs it on Windows → SimPilot Bridge.exe),
// so people can run the bridge without installing Node.js. Uses Node's single executable applications (SEA):
// the bridge is bundled into one CommonJS file, turned into a SEA blob and injected into a copy of this node binary.
// Then the result is started once with SIMPILOT_SMOKE_TEST=1 to prove it runs.
//   npm run package:exe            → dist/app/SimPilot Bridge(.exe)
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { inject } from 'postject';
import { stripCertificate } from './pe.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'dist', 'app');
const windows = process.platform === 'win32';
const mac = process.platform === 'darwin';
const exe = path.join(out, windows ? 'SimPilot Bridge.exe' : 'SimPilot Bridge');
const bundle = path.join(out, 'bridge.cjs');
const blob = path.join(out, 'sea-prep.blob');
const seaConfig = path.join(out, 'sea-config.json');

const major = Number(process.versions.node.split('.')[0]);
if (major < 22) throw new Error(`Packaging needs Node 22 or newer (this is ${process.version}).`);

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

console.log('1/4 Bundling the bridge');
const bundled = await build({
  absWorkingDir: root,
  entryPoints: [path.join(root, 'src', 'index.ts')],
  outfile: bundle,
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: `node${major}`,
  legalComments: 'eof',
  metafile: true,
  logLevel: 'warning',
  // Packaged mode: cache in local app data, keep error messages on screen (see src/config.ts and src/index.ts).
  define: { 'process.env.SIMPILOT_PACKAGED': '"1"', 'import.meta.url': '"file:///simpilot-bridge.cjs"' },
  // ws loads these optional native speed-ups inside try/catch and works without them.
  external: ['bufferutil', 'utf-8-validate'],
});

console.log('2/4 Creating the application blob');
fs.writeFileSync(seaConfig, JSON.stringify({
  main: bundle,
  output: blob,
  disableExperimentalSEAWarning: true,
  useSnapshot: false,
  useCodeCache: false,
}, null, 2));
execFileSync(process.execPath, ['--experimental-sea-config', seaConfig], { stdio: 'inherit' });

console.log('3/4 Building the executable');
fs.copyFileSync(process.execPath, exe);
if (windows) fs.writeFileSync(exe, stripCertificate(fs.readFileSync(exe)));
fs.chmodSync(exe, 0o755);
if (mac) execFileSync('codesign', ['--remove-signature', exe]);
await inject(exe, 'NODE_SEA_BLOB', fs.readFileSync(blob), {
  sentinelFuse: 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2',
  ...(mac ? { machoSegmentName: 'NODE_SEA' } : {}),
});
if (mac) execFileSync('codesign', ['--sign', '-', exe]);

// Keep the exact bridge and bundled dependency sources/notices available for rebuilding a modified copy.
const sources = path.join(out, 'Source and notices');
fs.mkdirSync(sources, { recursive: true });
fs.copyFileSync(path.join(root, '..', 'LICENSE'), path.join(sources, 'LICENSE'));
for (const item of ['src', 'scripts', 'package.json', 'package-lock.json', 'tsconfig.json']) {
  fs.cpSync(path.join(root, item), path.join(sources, 'bridge', item), { recursive: true });
}
const packages = new Set();
for (const input of Object.keys(bundled.metafile.inputs)) {
  const normalized = input.replaceAll('\\', '/');
  const match = [...normalized.matchAll(/(?:^|\/)node_modules\/((?:@[^/]+\/)?[^/]+)/g)].at(-1);
  if (match) packages.add(normalized.slice(0, match.index) + '/node_modules/' + match[1]);
}
for (const pkg of packages) {
  const relative = pkg.replace(/^\//, '');
  fs.cpSync(path.resolve(root, relative), path.join(sources, 'bridge', relative), { recursive: true });
}
const nodeDir = path.dirname(process.execPath);
const license = [path.join(nodeDir, 'LICENSE'), path.join(nodeDir, '..', 'LICENSE')].find((file) => fs.existsSync(file));
if (!license) throw new Error('Node LICENSE missing. Package with the complete official Node.js distribution.');
fs.copyFileSync(license, path.join(sources, 'Node-LICENSE.txt'));
fs.writeFileSync(path.join(sources, 'Read me.txt'), `SimPilot Bridge includes Node.js ${process.version} and the dependency versions in bridge/package-lock.json.\n` +
  'Their source files and license notices are included here. Node.js source: https://nodejs.org/dist/' + process.version + '/\n' +
  'To rebuild: install the official Node.js 22 distribution, open the bridge folder, run npm ci, then npm run package:exe.\n' +
  'You can modify or replace the included dependencies before rebuilding. Source: https://github.com/footfungus2/simpilot-efb\n');

console.log('4/4 Checking that it starts');
const check = spawnSync(exe, [], {
  env: { ...process.env, SIMPILOT_SMOKE_TEST: '1', SIMPILOT_PORT: '18380', SIMPILOT_CACHE_DIR: path.join(out, 'smoke-cache') },
  encoding: 'utf8',
  timeout: 60_000,
});
fs.rmSync(path.join(out, 'smoke-cache'), { recursive: true, force: true });
const output = `${check.stdout ?? ''}${check.stderr ?? ''}`;
if (check.status !== 0 || !output.includes('startup check passed')) {
  console.error(output);
  throw new Error(`The packaged bridge didn't start (exit ${check.status ?? check.signal ?? check.error}).`);
}
for (const f of [bundle, blob, seaConfig]) fs.rmSync(f);

console.log(`Built ${path.relative(root, exe)} (${(fs.statSync(exe).size / 1e6).toFixed(0)} MB)`);
