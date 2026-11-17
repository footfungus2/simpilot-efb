import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  listen: vi.fn(), close: vi.fn(), closeConnections: vi.fn(), closeHub: vi.fn(), stopSim: vi.fn(), startSim: vi.fn(),
  publish: vi.fn(), unpublish: vi.fn((done: () => void) => done()), destroy: vi.fn(),
}));
function listener() {
  return Object.assign(new EventEmitter(), {
    listening: false,
    listen: state.listen,
    close: state.close,
    closeAllConnections: state.closeConnections,
  });
}
let server: ReturnType<typeof listener>;
let secureServer: ReturnType<typeof listener>;
const key = 'a'.repeat(64);
const fingerprint = 'b'.repeat(64);
vi.mock('../src/config.js', () => ({ config: { port: 8386, securePort: 8387, cacheDir: 'cache', bridgeVersion: 'test' } }));
vi.mock('../src/auth.js', () => ({ loadOrCreatePairingKey: () => key }));
vi.mock('../src/tls.js', () => ({ loadOrCreateTls: async () => ({ fingerprint }) }));
vi.mock('../src/charts/store.js', () => ({ ChartStore: class {} }));
vi.mock('../src/fenix.js', () => ({ FenixProcedures: class {} }));
vi.mock('../src/lvars.js', () => ({ LVars: class {} }));
vi.mock('../src/hub.js', () => ({ Hub: class { close = state.closeHub; } }));
vi.mock('../src/server.js', () => ({ createServer: () => server, createSecureServer: () => secureServer }));
vi.mock('../src/sim.js', () => ({ startSim: state.startSim }));
vi.mock('bonjour-service', () => ({ Bonjour: class {
  publish = state.publish; unpublishAll = state.unpublish; destroy = state.destroy;
} }));

const events = ['SIGINT', 'SIGTERM', 'SIGHUP', 'uncaughtException', 'unhandledRejection'] as const;
let listeners: Map<string, Function[]>;
let stdinTTY: PropertyDescriptor | undefined;
let stdoutTTY: PropertyDescriptor | undefined;
beforeEach(() => {
  vi.resetModules(); vi.clearAllMocks();
  listeners = new Map(events.map((event) => [event, process.listeners(event)]));
  vi.stubEnv('SIMPILOT_PACKAGED', '1');
  vi.stubEnv('SIMPILOT_SMOKE_TEST', undefined);
  stdinTTY = Object.getOwnPropertyDescriptor(process.stdin, 'isTTY');
  stdoutTTY = Object.getOwnPropertyDescriptor(process.stdout, 'isTTY');
  Object.defineProperty(process.stdin, 'isTTY', { configurable: true, value: false });
  Object.defineProperty(process.stdout, 'isTTY', { configurable: true, value: false });
  vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  state.startSim.mockReturnValue(state.stopSim);
  server = listener();
  secureServer = listener();
});
afterEach(() => {
  for (const event of events) for (const listener of process.listeners(event)) {
    if (!listeners.get(event)!.includes(listener)) process.removeListener(event, listener);
  }
  vi.unstubAllEnvs();
  if (stdinTTY) Object.defineProperty(process.stdin, 'isTTY', stdinTTY); else Reflect.deleteProperty(process.stdin, 'isTTY');
  if (stdoutTTY) Object.defineProperty(process.stdout, 'isTTY', stdoutTTY); else Reflect.deleteProperty(process.stdout, 'isTTY');
  vi.restoreAllMocks();
});

async function waitForListeners() {
  await import('../src/index.js');
  await vi.waitFor(() => {
    expect(state.listen).toHaveBeenNthCalledWith(1, 8386, '127.0.0.1', expect.any(Function));
    expect(state.listen).toHaveBeenNthCalledWith(2, 8387, '0.0.0.0', expect.any(Function));
  });
}

function ready(bridge: ReturnType<typeof listener>, index: number) {
  bridge.listening = true;
  state.listen.mock.calls[index][2]();
}

it('does not start simulator/discovery work when the secure port is occupied', async () => {
  await waitForListeners();
  ready(server, 0);
  secureServer.emit('error', Object.assign(new Error('occupied'), { code: 'EADDRINUSE' }));
  await vi.waitFor(() => expect(process.exit).toHaveBeenCalledWith(1));
  expect(state.startSim).not.toHaveBeenCalled();
  expect(state.publish).not.toHaveBeenCalled();
  expect(state.close).toHaveBeenCalledTimes(1);
  expect(state.closeConnections).toHaveBeenCalledTimes(2);
  expect(state.closeHub).toHaveBeenCalledTimes(1);
});

it('stops every running service once before reporting a fatal exit', async () => {
  await waitForListeners();
  ready(server, 0);
  expect(state.startSim).not.toHaveBeenCalled();
  ready(secureServer, 1);
  const fatal = process.listeners('uncaughtException').find((listener) => !listeners.get('uncaughtException')!.includes(listener))!;
  fatal(new Error('test failure'), 'uncaughtException');
  await vi.waitFor(() => expect(process.exit).toHaveBeenCalledWith(1));
  expect(state.stopSim).toHaveBeenCalledTimes(1);
  expect(state.close).toHaveBeenCalledTimes(2);
  expect(state.closeConnections).toHaveBeenCalledTimes(2);
  expect(state.closeHub).toHaveBeenCalledTimes(1);
  expect(state.unpublish).toHaveBeenCalledTimes(1);
  expect(state.destroy).toHaveBeenCalledTimes(1);
  fatal(new Error('second failure'), 'uncaughtException');
  expect(state.stopSim).toHaveBeenCalledTimes(1);
});

it('withdraws discovery and exits normally when the console closes', async () => {
  await waitForListeners();
  ready(server, 0);
  ready(secureServer, 1);
  expect(console.log).not.toHaveBeenCalledWith(expect.stringContaining(key));
  const close = process.listeners('SIGHUP').find((listener) => !listeners.get('SIGHUP')!.includes(listener))!;
  close();
  await vi.waitFor(() => expect(process.exit).toHaveBeenCalledWith(0));
  expect(state.unpublish).toHaveBeenCalledTimes(1);
  expect(state.stopSim).toHaveBeenCalledTimes(1);
});

it('shows the pairing code in the interactive console', async () => {
  Object.defineProperty(process.stdout, 'isTTY', { configurable: true, value: true });
  await waitForListeners();
  ready(server, 0);
  ready(secureServer, 1);
  expect(console.log).toHaveBeenCalledWith(expect.stringContaining(`${key}:${fingerprint}`));
});
