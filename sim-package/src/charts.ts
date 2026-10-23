// Minimal re-implementation of the SDK's ChartsClient / ChartView (msfs-sdk 2.3.3) on top of the
// JS_LISTENER_CHARTS view listener. Bundling the whole SDK into a toolbar panel costs 2.4 MB and
// runs SDK top-level code in a view that wasn't built for it, so only the calls we need live here.
// Types come from the SDK (type-only imports, nothing is bundled).

import type { IcaoValue, SimChartIndex, SimChartPages } from '@microsoft/msfs-sdk';

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

export function getChartPages(guid: string): Promise<SimChartPages> {
  return requestCharts('GET_CHART_PAGES', guid);
}

/**
 * Asks the sim to load one chart page into a LiveView and resolves with the LiveView's image URL
 * (usable as an <img> src). The view is destroyed by the returned `release` function.
 */
export async function loadChartLiveView(pageUrl: string): Promise<{ imageUrl: string; release: () => void }> {
  const l = await listener();
  const creating = Promise.resolve().then(() => l.call('CREATE_CHART_VIEW') as Promise<string>);
  let viewId: string;
  const destroy = (id: string) => Promise.resolve().then(() => l.call('DESTROY_CHART_VIEW', id)).catch(() => {});
  try {
    viewId = await withTimeout(creating, REQUEST_TIMEOUT_MS, 'CREATE_CHART_VIEW');
  } catch (err) {
    void creating.then(destroy).catch(() => {});
    throw err;
  }
  let onName: (guid: string, name: string, chartUrl: string) => void = () => {};
  let onError: (guid: string, code: number, chartUrl: string) => void = () => {};
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    l.off('SendLiveViewName', onName);
    l.off('SendLiveViewError', onError);
    void destroy(viewId);
  };
  try {
    const imageUrl = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('ChartView timed out')), REQUEST_TIMEOUT_MS);
      onName = (guid, name, chartUrl) => {
        if (guid === viewId && chartUrl === pageUrl) {
          clearTimeout(timer);
          resolve(name);
        }
      };
      onError = (guid, code, chartUrl) => {
        if (guid === viewId && chartUrl === pageUrl) {
          clearTimeout(timer);
          reject(new Error(`ChartView error code ${code}`));
        }
      };
      l.on('SendLiveViewName', onName);
      l.on('SendLiveViewError', onError);
      void Promise.resolve().then(() => l.call('SET_CHART_VIEW_URL', viewId, pageUrl)).catch((err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
    return { imageUrl, release };
  } catch (err) {
    release();
    throw err;
  }
}
