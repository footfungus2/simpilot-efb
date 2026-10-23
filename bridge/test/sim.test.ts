import { EventEmitter } from 'node:events';
import { open } from 'node-simconnect';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Hub } from '../src/hub.js';
import type { LVars } from '../src/lvars.js';
import { startSim } from '../src/sim.js';

vi.mock('node-simconnect', async (original) => ({ ...await original<typeof import('node-simconnect')>(), open: vi.fn() }));

function fakeHandle() {
  return Object.assign(new EventEmitter(), {
    addToDataDefinition: vi.fn(),
    requestDataOnSimObject: vi.fn(),
    subscribeToSystemEvent: vi.fn(),
    close: vi.fn(),
  });
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.mocked(open).mockReset();
});

describe('simulator lifecycle', () => {
  async function start() {
    const handle = fakeHandle();
    const hub = { setSim: vi.fn(), ownship: vi.fn() };
    const lv = { attach: vi.fn(), detach: vi.fn(), onData: vi.fn() };
    vi.mocked(open).mockResolvedValueOnce({ handle, recvOpen: { applicationName: 'Test simulator' } } as unknown as Awaited<ReturnType<typeof open>>);
    vi.mocked(open).mockRejectedValue(new Error('simulator off'));
    startSim(hub as unknown as Hub, lv as unknown as LVars);
    await vi.advanceTimersByTimeAsync(0);
    return { handle, hub, lv };
  }

  it('disconnects once on a socket error and schedules one reconnect even after close', async () => {
    const { handle, hub, lv } = await start();
    handle.emit('error', new Error('connection lost'));
    handle.emit('close');
    expect(lv.detach).toHaveBeenCalledTimes(1);
    expect(hub.setSim).toHaveBeenLastCalledWith(false);
    expect(handle.close).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(5000);
    expect(open).toHaveBeenCalledTimes(2);
  });

  it('resets cockpit state on aircraft change and ignores data from a lost connection', async () => {
    const { handle, hub, lv } = await start();
    handle.emit('event', { clientEventId: 1 });
    expect(lv.attach).toHaveBeenCalledTimes(2);
    expect(hub.setSim).toHaveBeenLastCalledWith(true);
    handle.emit('quit');
    handle.emit('simObjectData', { requestID: 10, data: {} });
    expect(lv.onData).not.toHaveBeenCalled();
  });
});
