// Builds the Windows PC bundle without rewriting node.exe. CI runs this with the official Node.js runtime.
//   npm run package:portable → dist/app/SimPilot Bridge.cmd, node.exe and bridge.cjs
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

if (process.platform !== 'win32') throw new Error('Build the portable PC bundle on Windows.');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'dist', 'app');
const runtime = path.join(out, 'node.exe');
const bundle = path.join(out, 'bridge.cjs');
const launcher = path.join(out, 'SimPilot Bridge.cmd');
const major = Number(process.versions.node.split('.')[0]);
if (major < 22) throw new Error(`Packaging needs Node 22 or newer (this is ${process.version}).`);

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

console.log('1/3 Bundling the bridge');
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
  define: { 'process.env.SIMPILOT_PACKAGED': '"1"', 'import.meta.url': '"file:///simpilot-bridge.cjs"' },
  external: ['bufferutil', 'utf-8-validate'],
});

console.log('2/3 Copying the official Node.js runtime');
fs.copyFileSync(process.execPath, runtime);
fs.writeFileSync(launcher, '@echo off\r\nsetlocal\r\n"%~dp0node.exe" "%~dp0bridge.cjs"\r\nexit /b %ERRORLEVEL%\r\n');

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
fs.writeFileSync(path.join(sources, 'Read me.txt'), `SimPilot Bridge includes the unmodified Node.js ${process.version} Windows runtime and the dependency versions in bridge/package-lock.json.\n` +
  'Their source files and license notices are included here. Node.js source: https://nodejs.org/dist/' + process.version + '/\n' +
  'To rebuild: install the official Node.js 22 distribution, open the bridge folder, run npm ci, then npm run package:portable.\n' +
  'You can modify or replace the included dependencies before rebuilding. Source: https://github.com/footfungus2/simpilot-efb\n');

console.log('3/3 Checking the packaged runtime starts');
const check = spawnSync(runtime, [bundle], {
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

console.log(`Built ${path.relative(root, launcher)} with the unmodified Node.js runtime (${(fs.statSync(runtime).size / 1e6).toFixed(0)} MB)`);
