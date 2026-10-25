// Minimal re-implementation of the SDK's ChartsClient (msfs-sdk 2.3.3) on top of the
// JS_LISTENER_CHARTS view listener. Bundling the whole SDK into a toolbar panel costs 2.4 MB and
// runs SDK top-level code in a view that wasn't built for it, so only the calls we need live here.
// Types come from the SDK (type-only imports, nothing is bundled).

import type { IcaoValue, SimChartIndex } from '@microsoft/msfs-sdk';

interface ViewListener {
  call(name: string, ...args: unknown[]): Promise<any>;
  on(name: string, cb: (...args: any[]) => void): void;
  off(name: string, cb: (...args: any[]) => void): void;
}
declare function RegisterViewListener(name: string, onReady?: () => void): ViewListener;
declare global {
  interface Window {
    AtomicSequence?: { getNext(): number };
  }
}

const READY_TIMEOUT_MS = 10000;
const REQUEST_TIMEOUT_MS = 30000;

export function airportIcao(ident: string): IcaoValue {
  return { __Type: 'JS_ICAO', type: 'A', region: '', airport: '', ident } as unknown as IcaoValue;
}

let listenerPromise: Promise<ViewListener> | undefined;
let nextIdPromise: Promise<() => number> | undefined;
const pending = new Map<number, { resolve: (v: any) => void; reject: (e: unknown) => void; timer: ReturnType<typeof setTimeout> }>();

function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`${what} timed out`)), ms);
    p.then(
      (v) => (clearTimeout(t), resolve(v)),
      (e) => (clearTimeout(t), reject(e)),
    );
  });
}

function listener(): Promise<ViewListener> {
  listenerPromise ??= withTimeout(
    new Promise<ViewListener>((resolve) => {
      const l: ViewListener = RegisterViewListener('JS_LISTENER_CHARTS', () => resolve(l));
    }),
    READY_TIMEOUT_MS,
    'JS_LISTENER_CHARTS',
  ).then((l) => {
    const settle = (ok: boolean) => (id: number, value: unknown) => {
      const req = pending.get(id);
      if (!req) return;
      pending.delete(id);
      clearTimeout(req.timer);
      if (ok) req.resolve(value);
      else req.reject(new Error(`charts error code ${String(value)}`));
    };
    l.on('SendChartIndex', settle(true));
    l.on('SendChartIndexError', settle(false));
    l.on('SendChartPages', settle(true));
    l.on('SendChartPagesError', settle(false));
    return l;
  }).catch((err) => {
    listenerPromise = undefined;
    throw err;
  });
  return listenerPromise;
}

/** Request IDs come from the sim's shared atomic sequence so they never clash with other views (e.g. the EFB). */
function nextId(): Promise<number> {
  nextIdPromise ??= withTimeout(
    new Promise<() => number>((resolve, reject) => {
      RegisterViewListener('JS_LISTENER_ATOMIC', () => {
        const sequence = window.AtomicSequence;
        if (sequence) resolve(() => sequence.getNext());
        else reject(new Error('Atomic sequence unavailable'));
      });
    }),
    READY_TIMEOUT_MS,
    'JS_LISTENER_ATOMIC',
  ).catch(() => {
    // Fall back to a random range if the atomic listener isn't available in this view.
    let n = Math.floor(Math.random() * 1e9);
    return () => ++n;
  });
  return nextIdPromise.then((f) => f());
}

async function requestCharts<T>(call: string, ...args: unknown[]): Promise<T> {
  const l = await listener();
  const id = await nextId();
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${call} timed out`));
    }, REQUEST_TIMEOUT_MS);
    pending.set(id, { resolve, reject, timer });
    void Promise.resolve().then(() => l.call(call, id, ...args)).catch((err) => {
      if (!pending.delete(id)) return;
      clearTimeout(timer);
      reject(err);
    });
  });
}

export function getIndexForAirport(ident: string, provider: string): Promise<SimChartIndex<string>> {
  return requestCharts('GET_CHARTS_INDEX', airportIcao(ident), provider);
}
