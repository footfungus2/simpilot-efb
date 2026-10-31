import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = path.dirname(fileURLToPath(import.meta.url));
const assets = 'PackageSources/html_ui/InGamePanels/SimPilotLink/';
const inputs = ['build.mjs', 'src/charts.ts', 'src/link.ts', 'package-lock.json', `${assets}SimPilotLink.html`, `${assets}SimPilotLink.css`];
const hash = createHash('sha256');
for (const input of inputs) { hash.update(input); hash.update(await fs.readFile(path.join(root, input))); }
const buildId = hash.digest('hex').slice(0, 12);
await build({
  absWorkingDir: root,
  entryPoints: ['src/link.ts'], bundle: true, format: 'iife', target: 'es2017', legalComments: 'none',
  outfile: `${assets}link.js`, define: { __SIMPILOT_LINK_BUILD__: JSON.stringify(buildId) },
});
const files = [];
for (const name of ['SimPilotLink.html', 'SimPilotLink.css', 'link.js']) {
  const bytes = await fs.readFile(path.join(root, assets, name));
  files.push({ path: `InGamePanels/SimPilotLink/${name}`, sha256: createHash('sha256').update(bytes).digest('hex') });
}
await fs.writeFile(path.join(root, 'PackageSources/panel-assets.json'), JSON.stringify({ buildId, files }, null, 2) + '\n');
console.log(`Built SimPilot Link ${buildId} and asset hash manifest`);
