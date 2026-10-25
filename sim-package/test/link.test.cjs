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

async function exportJob(t, pages, { captureError } = {}) {
  let finish;
  const done = new Promise((resolve) => { finish = resolve; });
  let released = 0;
  const tiles = [];
  const srcAtRelease = [];
  const image = {
    style: {},
    naturalWidth: 1200,
    naturalHeight: 1700,
    setAttribute() {},
    get src() { return this._src; },
    set src(value) { this._src = value; if (value) queueMicrotask(() => this.onload?.()); },
  };
  const element = () => ({ style: {}, setAttribute() {}, appendChild() {}, clientWidth: 600, clientHeight: 400 });
  const { api } = run(t, 'link', {
    require: () => ({
      getIndexForAirport: async () => ({ charts: [{ charts: [{ guid: 'chart' }] }] }),
      getChartPages: async () => ({ pages }),
      loadChartLiveView: async () => ({ imageUrl: 'live-view', release() { released++; srcAtRelease.push(image.src); } }),
    }),
    document: {
      getElementById: () => null,
      body: { appendChild() {} },
      createElement: (tag) => (tag === 'img' ? image : element()),
    },
    TemplateElement: class {},
    window: { customElements: { define() {} } },
    checkAutoload() {},
    setInterval() {},
    XMLHttpRequest: class {
      open(method, url) { this.url = url; }
      setRequestHeader() {}
      send(raw) {
        const body = raw ? JSON.parse(raw) : {};
        let response = {};
        this.status = 200;
        if (this.url.endsWith('/link/poll')) response = { jobs: [{ id: 'job', icao: 'EGSS', provider: 'LIDO' }] };
        else if (this.url.endsWith('/link/capture')) {
          tiles.push(body);
          if (captureError) { this.status = 409; response = { error: captureError }; }
          else response = { saved: body.page === 0 && body.i === body.cols - 1 && body.j === body.rows - 1 };
        } else if (this.url.endsWith('/link/done')) finish(body);
        else if (!this.url.startsWith('http://127.0.0.1')) this.status = 500;
        this.responseText = JSON.stringify(response);
        queueMicrotask(() => this.onload());
      }
    },
  });
  return { result: await done, released, tiles, srcAtRelease, api };
}

const pageList = (n) => Array.from({ length: n }, (_, p) => ({ urls: [{ name: 'PNG', url: `https://charts.invalid/${p}.png` }] }));

test('partial export fails the job and releases each ChartView after detaching the image', async (t) => {
  const { result, released, srcAtRelease } = await exportJob(t, pageList(2));
  assert.match(result.error, /1 chart page\(s\) could not be exported/);
  assert.equal(released, 2);
  assert.deepEqual(srcAtRelease, ['', '']);
});

test('a chart with no pages fails the job', async (t) => {
  assert.match((await exportJob(t, [])).result.error, /could not be exported/);
});

test('a complete export captures every tile of the page', async (t) => {
  const { result, tiles } = await exportJob(t, pageList(1));
  assert.equal(result.error, undefined);
  // 600×400 view, 1200×1700 image: 2 columns × 5 rows covering the page.
  assert.deepEqual(tiles.map((b) => [b.i, b.j]), [0, 1, 2, 3, 4].flatMap((j) => [[0, j], [1, j]]));
  assert.deepEqual(tiles[0].view, { w: 600, h: 400 });
  assert.deepEqual(tiles[0].image, { w: 1200, h: 1700 });
});

test('a capture error stops the job with the bridge\'s message', async (t) => {
  const { result, released, tiles } = await exportJob(t, pageList(3), { captureError: "Can't see the SimPilot Link window" });
  assert.match(result.error, /Can't see the SimPilot Link window/);
  assert.equal(released, 1);
  assert.equal(tiles.length, 1);
});

test('the tile layout stays sharp but bounded', async (t) => {
  const { api } = await exportJob(t, pageList(1));
  // Never wider than the chart image itself.
  assert.equal(api.captureLayout(600, 400, 500, 700).cols, 1);
  // A small window drops columns rather than taking more than 16 tiles.
  const small = api.captureLayout(300, 200, 2000, 2800);
  assert.ok(small.cols * small.rows <= 16 || small.cols === 1);
  assert.ok(small.rows * 200 >= small.h);
});
