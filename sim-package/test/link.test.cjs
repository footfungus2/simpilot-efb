const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const { runInNewContext } = require('node:vm');
const { transformSync } = require('esbuild');

function run(t, file, globals) {
  const timers = new Set();
  t.after(() => timers.forEach(clearTimeout));
  const context = {
    module: { exports: {} },
    setTimeout(fn, ms) {
      const timer = setTimeout(() => { timers.delete(timer); fn(); }, Math.min(ms, 30));
      timers.add(timer);
      return timer;
    },
    clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); },
    ...globals,
  };
  // MSFS Coherent does not provide Array.flatMap.
  runInNewContext('Array.prototype.flatMap = undefined', context);
  const source = readFileSync(`${__dirname}/../src/${file}.ts`, 'utf8');
  runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs', target: 'es2017' }).code, context);
  return { api: context.module.exports, timers };
}

function charts(t, onCall, ready = () => true, hasAtomic = true) {
  const events = new Map();
  const calls = [];
  const listener = {
    call(name, ...args) {
      calls.push([name, ...args]);
      return onCall(name, args, events) ?? Promise.resolve();
    },
    on(name, cb) { events.set(name, cb); },
    off(name) { events.delete(name); },
  };
  let id = 0;
  const result = run(t, 'charts', {
    window: { AtomicSequence: hasAtomic ? { getNext: () => ++id } : undefined },
    RegisterViewListener(name, cb) {
      if (ready(name)) queueMicrotask(cb);
      return listener;
    },
  });
  return { ...result, events, calls };
}

test('chart command rejection clears its pending timeout', async (t) => {
  const { api, timers } = charts(t, () => Promise.reject(new Error('sim disconnected')));
  await assert.rejects(api.getIndexForAirport('EGSS', 'LIDO'), /sim disconnected/);
  assert.equal(timers.size, 0);
});

test('chart listener can recover after a readiness timeout', async (t) => {
  let attempts = 0;
  const { api } = charts(t, (name, [id], events) => {
    if (name === 'GET_CHARTS_INDEX') queueMicrotask(() => events.get('SendChartIndex')(id, { charts: [] }));
  }, (name) => name !== 'JS_LISTENER_CHARTS' || ++attempts > 1);
  await assert.rejects(api.getIndexForAirport('EGSS', 'LIDO'), /timed out/);
  assert.equal((await api.getIndexForAirport('EGSS', 'LIDO')).charts.length, 0);
});

test('requests still work when the atomic listener has no sequence', async (t) => {
  const { api } = charts(t, (name, [id], events) => {
    if (name === 'GET_CHARTS_INDEX') queueMicrotask(() => events.get('SendChartIndex')(id, { charts: [] }));
  }, () => true, false);
  assert.equal((await api.getIndexForAirport('EGSS', 'LIDO')).charts.length, 0);
});

async function exportJob(t) {
  let finish;
  const done = new Promise((resolve) => { finish = resolve; });
  const posted = [];
  run(t, 'link', {
    require: () => ({
      getIndexForAirport: async () => ({ charts: [{ charts: [{ guid: 'chart' }] }] }),
    }),
    document: { getElementById: () => null },
    TemplateElement: class {},
    window: { customElements: { define() {} } },
    checkAutoload() {},
    setInterval() {},
    XMLHttpRequest: class {
      open(method, url) { this.url = url; posted.push(url); }
      setRequestHeader() {}
      send(raw) {
        const body = raw ? JSON.parse(raw) : {};
        let response = {};
        this.status = 200;
        if (this.url.endsWith('/link/poll')) response = { jobs: [{ id: 'job', icao: 'EGSS', provider: 'LIDO' }] };
        else if (this.url.endsWith('/link/done')) finish(body);
        else if (!this.url.startsWith('http://127.0.0.1')) this.status = 500;
        this.responseText = JSON.stringify(response);
        queueMicrotask(() => this.onload());
      }
    },
  });
  return { result: await done, posted };
}

test('a chart job lists the charts and fails without exporting images', async (t) => {
  const { result, posted } = await exportJob(t);
  assert.match(result.error, /1 charts for EGSS but doesn't let add-ons copy chart images/);
  assert.ok(!posted.some((url) => url.endsWith('/link/image')));
});
