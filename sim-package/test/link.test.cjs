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

test('a chart view created after its timeout is still destroyed', async (t) => {
  let created;
  const { api, calls } = charts(t, (name) => {
    if (name === 'CREATE_CHART_VIEW') return new Promise((resolve) => { created = resolve; });
    if (name === 'DESTROY_CHART_VIEW') return Promise.reject(new Error('already disconnected'));
  });
  await assert.rejects(api.loadChartLiveView('chart.png'), /CREATE_CHART_VIEW timed out/);
  created('late-view');
  await new Promise(setImmediate);
  assert.ok(calls.some(([name, id]) => name === 'DESTROY_CHART_VIEW' && id === 'late-view'));
});

test('rejected chart URL cleans up the view and listeners immediately', async (t) => {
  const { api, calls, events, timers } = charts(t, (name) => {
    if (name === 'CREATE_CHART_VIEW') return Promise.resolve('view');
    if (name === 'SET_CHART_VIEW_URL') return Promise.reject(new Error('cannot load chart'));
  });
  await assert.rejects(api.loadChartLiveView('chart.png'), /cannot load chart/);
  assert.ok(!events.has('SendLiveViewName') && !events.has('SendLiveViewError'));
  assert.equal(timers.size, 0);
  assert.ok(calls.some(([name]) => name === 'DESTROY_CHART_VIEW'));
});

async function exportJob(t, pages, dataUrl = `data:image/png;base64,${'A'.repeat(100)}`) {
  let finish;
  const done = new Promise((resolve) => { finish = resolve; });
  let released = 0;
  run(t, 'link', {
    require: () => ({
      getIndexForAirport: async () => ({ charts: [{ charts: [{ guid: 'chart' }] }] }),
      getChartPages: async () => ({ pages }),
      loadChartLiveView: async () => ({ imageUrl: 'live-view', release() { released++; } }),
    }),
    document: {
      getElementById: () => null,
      createElement: () => ({ getContext: () => ({ drawImage() {} }), toDataURL: () => dataUrl }),
    },
    TemplateElement: class {},
    window: { customElements: { define() {} } },
    checkAutoload() {},
    setInterval() {},
    Image: class {
      naturalWidth = 1;
      naturalHeight = 1;
      set src(_value) { queueMicrotask(() => this.onload?.()); }
    },
    XMLHttpRequest: class {
      open(method, url) { this.url = url; }
      setRequestHeader() {}
      overrideMimeType() {}
      send(raw) {
        const body = raw ? JSON.parse(raw) : {};
        let response = {};
        this.status = 200;
        if (this.url.endsWith('/link/poll')) response = { jobs: [{ id: 'job', icao: 'EGSS', provider: 'LIDO' }] };
        else if (this.url.endsWith('/link/image')) response = { saved: body.page === 0 };
        else if (this.url.endsWith('/link/done')) finish(body);
        else if (!this.url.startsWith('http://127.0.0.1')) this.status = 500;
        this.responseText = JSON.stringify(response);
        queueMicrotask(() => this.onload());
      }
    },
  });
  return { result: await done, released };
}

test('partial export fails the job and releases each ChartView', async (t) => {
  const pages = [0, 1].map((p) => ({ urls: [{ name: 'PNG', url: `https://charts.invalid/${p}.png` }] }));
  const { result, released } = await exportJob(t, pages);
  assert.match(result.error, /1 chart page\(s\) could not be exported/);
  assert.equal(released, 2);
});

test('a chart with no pages fails the job', async (t) => {
  assert.match((await exportJob(t, [])).result.error, /could not be exported/);
});

test('a complete export reports success', async (t) => {
  const { result } = await exportJob(t, [{ urls: [{ name: 'PNG', url: 'https://charts.invalid/0.png' }] }]);
  assert.equal(result.error, undefined);
});

test('blocked canvas readback stops the job after the first page', async (t) => {
  const pages = [0, 1, 2].map((p) => ({ urls: [{ name: 'PNG', url: `https://charts.invalid/${p}.png` }] }));
  const { result, released } = await exportJob(t, pages, 'data:,');
  assert.match(result.error, /canvas readback blocked/);
  assert.equal(released, 1);
});
