import os from 'node:os';
import { logger } from './log.js';

const log = logger('bridge');
const packaged = process.env.SIMPILOT_PACKAGED === '1';
const smokeTest = process.env.SIMPILOT_SMOKE_TEST === '1';
let stopping = false;
let cleanup: () => Promise<void> = async () => {};
process.title = 'SimPilot Bridge';

// Register before loading config: a bad setting must remain readable in a double-clicked window too.
process.on('uncaughtException', (err) => void finish(1, `SimPilot Bridge stopped: ${err.message}`));
process.on('unhandledRejection', (err) => void finish(1, `SimPilot Bridge stopped: ${err instanceof Error ? err.message : String(err)}`));
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP'] as const) process.on(signal, () => void finish(0));
void start().catch((err: Error) => finish(1, `SimPilot Bridge couldn't start: ${err.message}`));

async function start(): Promise<void> {
  const [{ config }, { Bonjour }, { ChartStore }, { Hub }, { FenixProcedures }, { LVars }, { createServer }, { startSim }] = await Promise.all([
    import('./config.js'), import('bonjour-service'), import('./charts/store.js'), import('./hub.js'),
    import('./fenix.js'), import('./lvars.js'), import('./server.js'), import('./sim.js'),
  ]);
  if (stopping) return;
  const hub = new Hub();
  const store = new ChartStore(config.cacheDir);
  const lvars = new LVars((values) => hub.broadcast({ t: 'lvars', values }));
  const server = createServer(hub, store, lvars, new FenixProcedures(lvars));
  let stopSim: (() => void) | undefined;
  let discovery: InstanceType<typeof Bonjour> | undefined;
  cleanup = async () => {
    stopSim?.();
    hub.close();
    server.close();
    server.closeAllConnections();
    if (discovery) {
      const bonjour = discovery;
      await new Promise<void>((resolve) => {
        const timeout = setTimeout(resolve, 500);
        bonjour.unpublishAll(() => { clearTimeout(timeout); resolve(); });
      });
      bonjour.destroy();
    }
  };
  server.on('error', (err: NodeJS.ErrnoException) => void finish(1, err.code === 'EADDRINUSE'
    ? `Port ${config.port} is already in use. If SimPilot Bridge is open, keep using that window and close this one. Otherwise close the program using that port and try again.`
    : `SimPilot Bridge couldn't start: ${err.message}`));

  server.listen(config.port, '0.0.0.0', () => {
    if (smokeTest) {
      log.info(`startup check passed (port ${config.port})`);
      process.exit(0);
    }
    stopSim = startSim(hub, lvars);
    welcome(config.port, config.bridgeVersion);
    // Discovery failures should not take down the working manual-address connection.
    discovery = new Bonjour(undefined, (err: Error) => log.warn('Local discovery unavailable; use the PC address in Settings > Bridge', err));
    discovery.publish({ name: `SimPilot Bridge (${os.hostname()})`, type: 'simpilot', port: config.port, txt: { v: '1' } });
    log.info(`listening on port ${config.port}; chart cache: ${config.cacheDir}`);
  });
}

function welcome(port: number, version: string): void {
  console.log(`\n  SimPilot Bridge ${version} is running. Leave this window open while you fly.`);
  console.log('  Keep the iPad and PC on the same local network (Wi-Fi or Ethernet).');
  const adapters = Object.entries(os.networkInterfaces()).flatMap(([name, entries]) =>
    (entries ?? []).filter((i) => i.family === 'IPv4' && !i.internal).map((i) => ({ name, address: i.address })));
  adapters.sort((a, b) => Number(/vpn|virtual|vethernet|vmware|wsl|tun|docker/i.test(a.name)) - Number(/vpn|virtual|vethernet|vmware|wsl|tun|docker/i.test(b.name)));
  if (adapters.length) {
    console.log('  If the app cannot find the PC, type its Wi-Fi or Ethernet address in Settings > Bridge:');
    for (const adapter of adapters) console.log(`    ${adapter.name}: ${adapter.address}:${port}`);
  }
  console.log('  MSFS 2024 connects automatically whenever it is running. To stop, close this window.');
  if (process.platform === 'win32') {
    console.log('  Windows may call this app "Node.js JavaScript Runtime" in its firewall prompt. Allow Private networks.');
    console.log('  If clicking/selecting text pauses this window, press Esc to resume.');
  }
  console.log('');
}

async function finish(code: number, message?: string): Promise<void> {
  if (stopping) return;
  stopping = true;
  if (message) log.error(message);
  try { await cleanup(); } catch (err) { log.warn('Could not finish cleanup', err); }
  if (code !== 0 && packaged && process.stdin.isTTY) {
    console.error('\nPress Enter to close this window.');
    process.stdin.resume();
    process.stdin.once('data', () => process.exit(code));
  } else {
    process.exit(code);
  }
}
