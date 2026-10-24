import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const state = vi.hoisted(() => ({
  listen: vi.fn(), close: vi.fn(), closeConnections: vi.fn(), closeHub: vi.fn(), stopSim: vi.fn(), startSim: vi.fn(),
  publish: vi.fn(), unpublish: vi.fn((done: () => void) => done()), destroy: vi.fn(),
}));
let server: EventEmitter;
vi.mock('../src/config.js', () => ({ config: { port: 8380, cacheDir: 'cache', bridgeVersion: 'test' } }));
vi.mock('../src/charts/store.js', () => ({ ChartStore: class {} }));
vi.mock('../src/fenix.js', () => ({ FenixProcedures: class {} }));
vi.mock('../src/lvars.js', () => ({ LVars: class {} }));
vi.mock('../src/hub.js', () => ({ Hub: class { close = state.closeHub; } }));
vi.mock('../src/server.js', () => ({ createServer: () => server }));
vi.mock('../src/sim.js', () => ({ startSim: state.startSim }));
vi.mock('bonjour-service', () => ({ Bonjour: class {
  publish = state.publish; unpublishAll = state.unpublish; destroy = state.destroy;
} }));

const events = ['SIGINT', 'SIGTERM', 'SIGHUP', 'uncaughtException', 'unhandledRejection'] as const;
let listeners: Map<string, Function[]>;
let packaged: string | undefined;
let tty: PropertyDescriptor | undefined;
beforeEach(() => {
  vi.resetModules(); vi.clearAllMocks();
  listeners = new Map(events.map((event) => [event, process.listeners(event)]));
  packaged = process.env.SIMPILOT_PACKAGED;
  process.env.SIMPILOT_PACKAGED = '1';
  tty = Object.getOwnPropertyDescriptor(process.stdin, 'isTTY');
  Object.defineProperty(process.stdin, 'isTTY', { configurable: true, value: false });
  vi.spyOn(process, 'exit').mockImplementation(() => undefined as never);
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
  state.startSim.mockReturnValue(state.stopSim);
  server = Object.assign(new EventEmitter(), { listen: state.listen, close: state.close, closeAllConnections: state.closeConnections });
});
afterEach(() => {
  for (const event of events) for (const listener of process.listeners(event)) {
    if (!listeners.get(event)!.includes(listener)) process.removeListener(event, listener);
  }
  if (packaged === undefined) delete process.env.SIMPILOT_PACKAGED; else process.env.SIMPILOT_PACKAGED = packaged;
  if (tty) Object.defineProperty(process.stdin, 'isTTY', tty); else Reflect.deleteProperty(process.stdin, 'isTTY');
  vi.restoreAllMocks();
});

it('does not start simulator/discovery work when the port is occupied', async () => {
  await import('../src/index.js');
  await vi.waitFor(() => expect(state.listen).toHaveBeenCalled());
  server.emit('error', Object.assign(new Error('occupied'), { code: 'EADDRINUSE' }));
  await vi.waitFor(() => expect(process.exit).toHaveBeenCalledWith(1));
  expect(state.startSim).not.toHaveBeenCalled();
  expect(state.publish).not.toHaveBeenCalled();
  expect(state.close).toHaveBeenCalledTimes(1);
  expect(state.closeHub).toHaveBeenCalledTimes(1);
});

it('stops every running service once before reporting a fatal exit', async () => {
  await import('../src/index.js');
  await vi.waitFor(() => expect(state.listen).toHaveBeenCalled());
  state.listen.mock.calls[0][2]();
  const fatal = process.listeners('uncaughtException').find((listener) => !listeners.get('uncaughtException')!.includes(listener))!;
  fatal(new Error('test failure'), 'uncaughtException');
  await vi.waitFor(() => expect(process.exit).toHaveBeenCalledWith(1));
  expect(state.stopSim).toHaveBeenCalledTimes(1);
  expect(state.close).toHaveBeenCalledTimes(1);
  expect(state.closeConnections).toHaveBeenCalledTimes(1);
  expect(state.closeHub).toHaveBeenCalledTimes(1);
  expect(state.unpublish).toHaveBeenCalledTimes(1);
  expect(state.destroy).toHaveBeenCalledTimes(1);
  fatal(new Error('second failure'), 'uncaughtException');
  expect(state.stopSim).toHaveBeenCalledTimes(1);
});

it('withdraws discovery and exits normally when the console closes', async () => {
  await import('../src/index.js');
  await vi.waitFor(() => expect(state.listen).toHaveBeenCalled());
  state.listen.mock.calls[0][2]();
  const close = process.listeners('SIGHUP').find((listener) => !listeners.get('SIGHUP')!.includes(listener))!;
  close();
  await vi.waitFor(() => expect(process.exit).toHaveBeenCalledWith(0));
  expect(state.unpublish).toHaveBeenCalledTimes(1);
  expect(state.stopSim).toHaveBeenCalledTimes(1);
});
