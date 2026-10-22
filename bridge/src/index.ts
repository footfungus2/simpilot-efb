import os from 'node:os';
import { Bonjour } from 'bonjour-service';
import { ChartStore } from './charts/store.js';
import { config } from './config.js';
import { Hub } from './hub.js';
import { logger } from './log.js';
import { LVars } from './lvars.js';
import { createServer } from './server.js';
import { startSim } from './sim.js';

const log = logger('bridge');

const hub = new Hub();
const store = new ChartStore(config.cacheDir);
const lvars = new LVars((values) => hub.broadcast({ t: 'lvars', values }));
const server = createServer(hub, store, lvars);

server.listen(config.port, '0.0.0.0', () => {
  log.info(`SimPilot EFB bridge ${config.bridgeVersion} listening on port ${config.port}`);
  for (const addr of lanAddresses()) log.info(`  iPad: enter ${addr}:${config.port} if auto-discovery doesn't find this PC`);
  log.info(`  chart cache: ${config.cacheDir}`);

  // Lets the iPad find the bridge without typing an IP address.
  const bonjour = new Bonjour();
  bonjour.publish({ name: `SimPilot Bridge (${os.hostname()})`, type: 'simpilot', port: config.port, txt: { v: '1' } });
  const shutdown = () => {
    bonjour.unpublishAll(() => {
      bonjour.destroy();
      process.exit(0);
    });
    setTimeout(() => process.exit(0), 1000).unref();
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
});

startSim(hub, lvars);

function lanAddresses(): string[] {
  return Object.values(os.networkInterfaces())
    .flat()
    .filter((i): i is os.NetworkInterfaceInfo => !!i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
}
