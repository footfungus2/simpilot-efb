const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const { runInNewContext } = require('node:vm');
const { transformSync } = require('esbuild');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

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

async function exportJob(t, pages, { captureError, have = [], savedPages = [0], pollWhileBusy = false, silentImage = false, natural = { w: 1200, h: 1700 }, job = { id: 'job', type: 'chart', icao: 'EGSS', provider: 'LIDO', guid: 'chart' } } = {}) {
  let finish;
  const done = new Promise((resolve) => { finish = resolve; });
  let released = 0;
  const tiles = [];
  const posted = [];
  const busyPolls = [];
  let interval;
  const srcAtRelease = [];
  const image = {
    style: {},
    naturalWidth: natural.w,
    naturalHeight: natural.h,
    setAttribute() {},
    get src() { return this._src; },
    set src(value) { this._src = value; if (value && !silentImage) queueMicrotask(() => this.onload?.()); },
  };
  const element = () => ({ style: {}, setAttribute() {}, appendChild() {}, clientWidth: 600, clientHeight: 400 });
  const { api } = run(t, 'link', {
    require: () => ({
      getIndexForAirport: async () => ({ charts: [{ charts: [{ guid: 'chart' }, { guid: 'chart-2' }] }, { charts: [{ guid: 'chart-3' }] }] }),
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
    setInterval(fn) { interval = fn; },
    XMLHttpRequest: class {
      open(method, url) { this.url = url; }
      setRequestHeader() {}
      send(raw) {
        const body = raw ? JSON.parse(raw) : {};
        let response = {};
        this.status = 200;
        if (!this.url.includes('/link/poll') && !this.url.endsWith('/api/status')) posted.push([this.url.replace('http://127.0.0.1:8386', ''), body]);
        if (this.url.includes('busy=1')) busyPolls.push(this.url);
        if (this.url.includes('/link/poll')) response = { jobs: this.url.includes('busy=1') ? [] : [job] };
        else if (this.url.endsWith('/api/status')) response = healthyBridge;
        else if (this.url.endsWith('/link/pages')) response = { ok: true, have };
        else if (this.url.endsWith('/link/capture')) {
          tiles.push(body);
          if (pollWhileBusy && tiles.length === 1) interval();
          if (captureError) { this.status = 409; response = { error: captureError }; }
          else response = { saved: savedPages.includes(body.page) && body.i === body.cols - 1 && body.j === body.rows - 1 };
        } else if (this.url.endsWith('/link/done')) finish(body);
        else if (!this.url.startsWith('http://127.0.0.1')) this.status = 500;
        this.responseText = JSON.stringify(response);
        queueMicrotask(() => this.onload());
      }
    },
  });
  return { result: await done, released, tiles, srcAtRelease, api, posted, busyPolls };
}

test('an image that never reports loading is captured anyway', async (t) => {
  const { result, tiles } = await exportJob(t, pageList(1), { silentImage: true });
  assert.equal(result.error, undefined);
  assert.ok(tiles.length > 1);
});

test('a page whose image size is unknown is captured at the page size the sim gave', async (t) => {
  const { result, tiles } = await exportJob(t, [{ width: 1000, height: 2000, urls: [{ name: 'PNG', url: 'https://charts.invalid/0.png' }] }], { silentImage: true, natural: { w: 0, h: 0 } });
  assert.equal(result.error, undefined);
  assert.deepEqual(tiles[0].image, { w: 1000, h: 2000 });
});

test('a tiny page size is taken for arbitrary units, not pixels', async (t) => {
  const { api } = await exportJob(t, pageList(1));
  assert.deepEqual({ ...api.pageSize({ naturalWidth: 0, naturalHeight: 0 }, { width: 100, height: 200 }) }, { w: 1800, h: 3600, from: 'assumed' });
  assert.equal(api.pageSize({ naturalWidth: 2480, naturalHeight: 3508 }, { width: 100, height: 200 }).w, 2480);
});

test('each tile is numbered on screen for the bridge to check', async (t) => {
  const { api } = await exportJob(t, pageList(1));
  const cells = Array.from({ length: 8 }, () => ({ style: {} }));
  const value = () => cells.reduce((n, c, k) => n + (c.style.background === '#fff' ? 1 << k : 0), 0);
  api.setTileCode(cells, 0);
  assert.equal(value(), 1);
  api.setTileCode(cells, 35);
  assert.equal(value(), 36);
});

const pageList = (n) => Array.from({ length: n }, (_, p) => ({ urls: [{ name: 'PNG', url: `https://charts.invalid/${p}.png` }] }));

test('partial export fails the job and releases each ChartView after detaching the image', async (t) => {
  const { result, released, srcAtRelease } = await exportJob(t, pageList(2));
  assert.match(result.error, /1 chart page\(s\) could not be exported/);
  assert.equal(released, 2);
  assert.deepEqual(srcAtRelease, ['', '']);
});

test('a chart with no pages fails the job', async (t) => {
  assert.match((await exportJob(t, [])).result.error, /no pages/);
});

test('a complete export captures every tile of the page', async (t) => {
  const { result, tiles } = await exportJob(t, pageList(1));
  assert.equal(result.error, undefined);
  // 600×400 view, 1200×1700 image, shown at its own size: 2 columns × 5 rows covering the page.
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
  // One panel pixel per image pixel when that fits...
  const native = api.captureLayout(600, 400, 1200, 1700);
  assert.deepEqual({ ...native }, { cols: 2, rows: 5, w: 1200, h: 1700 });
  assert.equal(api.captureLayout(600, 400, 500, 700).cols, 1);
  // ...and a small window shrinks the page rather than taking more than 36 tiles.
  const small = api.captureLayout(300, 200, 2480, 3508);
  assert.ok(small.cols * small.rows <= 36);
  assert.ok(small.rows * 200 >= small.h && small.cols * 300 >= small.w);
});

test('an airport job only sends the chart list, without opening a chart view', async (t) => {
  const { result, released, tiles, posted } = await exportJob(t, pageList(1), { job: { id: 'list', type: 'index', icao: 'EGSS', provider: 'LIDO' } });
  assert.equal(result.error, undefined);
  assert.equal(released, 0);
  assert.equal(tiles.length, 0);
  assert.deepEqual(posted.map(([url]) => url).filter((url) => url !== '/link/log'), ['/link/index', '/link/done']);
  assert.equal(posted.find(([url]) => url === '/link/index')[1].index.charts.length, 2);
});

test('a chart job skips the pages the bridge already has', async (t) => {
  const { result, tiles, released } = await exportJob(t, pageList(3), { have: [0, 2], savedPages: [1] });
  assert.equal(result.error, undefined);
  assert.equal(released, 1);
  assert.deepEqual([...new Set(tiles.map((b) => b.page))], [1]);
});

test('a chart job that has everything exported captures nothing', async (t) => {
  const { result, tiles } = await exportJob(t, pageList(2), { have: [0, 1] });
  assert.equal(result.error, undefined);
  assert.equal(tiles.length, 0);
});

test('an unknown job type is reported back instead of being ignored', async (t) => {
  const { result } = await exportJob(t, pageList(1), { job: { id: 'job', type: 'other', icao: 'EGSS', provider: 'LIDO' } });
  assert.match(result.error, /Unknown job type/);
});

test('while an export runs the panel only tells the bridge it is still there', async (t) => {
  const { result, busyPolls, tiles } = await exportJob(t, pageList(1), { pollWhileBusy: true, savedPages: [0] });
  assert.equal(result.error, undefined);
  assert.deepEqual(busyPolls, ['http://127.0.0.1:8386/link/poll?proto=3&busy=1']);
  assert.ok(tiles.length > 1, 'the export carried on');
});

const healthyBridge = { sim: { connected: true }, link: { connected: false }, bridge: { name: 'SimPilot Bridge', version: '0.1.4', buildId: 'fixture', linkProtocol: 3, port: 8386 } };

function bridgePanel(t, answer, { health = healthyBridge } = {}) {
  const status = { textContent: 'searching…' };
  const timers = new Map();
  const requests = [];
  let tick;
  let aborted = 0;
  run(t, 'link', {
    require: () => ({}),
    document: { getElementById: (id) => (id === 'spl-bridge' ? status : null), body: { appendChild() {} } },
    TemplateElement: class {},
    window: { customElements: { define() {} } },
    checkAutoload() {},
    setInterval(fn) { tick = fn; },
    setTimeout(fn) { const id = Symbol(); timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
    XMLHttpRequest: class {
      open(method, url) { this.url = url; }
      setRequestHeader() {}
      send() {
        requests.push(this);
        queueMicrotask(() => {
          if (this.url.endsWith('/link/log')) {
            this.status = 200; this.responseText = '{}'; this.onload?.();
          } else if (this.url.endsWith('/api/status') && health !== null) {
            this.status = 200; this.responseText = JSON.stringify(health); this.onload?.();
          } else answer(this);
        });
      }
      abort() { aborted++; this.readyState = 4; this.status = 0; this.onreadystatechange?.(); this.onabort?.(); }
    },
  });
  return { status, timers, requests, tick: () => tick(), get aborted() { return aborted; } };
}

async function bridgeStatus(t, answer, options) {
  const panel = bridgePanel(t, answer, options);
  await new Promise(setImmediate);
  return panel.status.textContent;
}

test('the panel says to start the bridge when nothing answers', async (t) => {
  assert.equal(await bridgeStatus(t, (xhr) => xhr.onerror()), 'not found: start SimPilot Bridge on this PC');
});

test('the panel preserves HTTP errors and identifies an unrelated status response', async (t) => {
  const text = await bridgeStatus(t, (xhr) => { xhr.status = 404; xhr.responseText = 'Cannot GET'; xhr.onload(); }, { health: null });
  assert.equal(text, 'connection failed: HTTP 404');
  const other = await bridgeStatus(t, (xhr) => { xhr.status = 200; xhr.responseText = '{"ok":true}'; xhr.onload(); }, { health: null });
  assert.equal(other, 'port 8386: not SimPilot Bridge');
});

test('the panel shows connected once SimPilot Bridge answers', async (t) => {
  assert.equal(await bridgeStatus(t, (xhr) => { xhr.status = 200; xhr.responseText = '{"jobs":[]}'; xhr.onload(); }), 'connected');
});

test('the panel connects when XHR only reports ready-state changes', async (t) => {
  const panel = bridgePanel(t, (xhr) => {
    xhr.readyState = 2;
    xhr.onreadystatechange?.();
    assert.equal(panel.status.textContent, 'searching…');
    xhr.status = 200;
    xhr.responseText = '{"jobs":[]}';
    xhr.readyState = 4;
    xhr.onreadystatechange?.();
  });
  await new Promise(setImmediate);
  assert.equal(panel.status.textContent, 'connected');
  assert.equal(panel.timers.size, 0);
});

test('a silent XHR times out, aborts and lets the next poll connect', async (t) => {
  const panel = bridgePanel(t, (xhr) => {
    if (panel.requests.filter((request) => request.url.includes('/link/poll')).length === 1) return;
    xhr.status = 200;
    xhr.responseText = '{"jobs":[]}';
    xhr.onload();
  });
  await new Promise(setImmediate);
  assert.equal(panel.timers.size, 1);
  panel.timers.values().next().value();
  await new Promise(setImmediate);
  assert.equal(panel.aborted, 1);
  assert.equal(panel.timers.size, 0);
  assert.equal(panel.status.textContent, 'not found: start SimPilot Bridge on this PC');
  panel.tick();
  await new Promise(setImmediate);
  assert.equal(panel.status.textContent, 'connected');
  assert.equal(panel.requests.filter((xhr) => xhr.url.includes('/link/poll')).length, 2);
  assert.ok(panel.requests.every((xhr) => !xhr.url.includes('busy=1')));
  assert.equal(panel.timers.size, 0);
});

test('ready-state completion with status zero is a network failure', async (t) => {
  assert.equal(await bridgeStatus(t, (xhr) => {
    xhr.readyState = 4;
    xhr.status = 0;
    xhr.onreadystatechange?.();
  }), 'not found: start SimPilot Bridge on this PC');
});

test('a rejected Origin is reported as the bridge HTTP error', async (t) => {
  assert.equal(await bridgeStatus(t, (xhr) => {
    xhr.status = 403;
    xhr.responseText = '{"error":"unsupported Origin; use coui://"}';
    xhr.onload();
  }, { health: null }), 'connection failed: HTTP 403: unsupported Origin; use coui://');
});

test('an incompatible protocol never polls for jobs or shows connected', async (t) => {
  const panel = bridgePanel(t, () => assert.fail('must not poll'), {
    health: { ...healthyBridge, bridge: { ...healthyBridge.bridge, linkProtocol: 99 } },
  });
  await new Promise(setImmediate);
  assert.match(panel.status.textContent, /protocol 99 is incompatible/);
  assert.equal(panel.requests.length, 1);
  assert.ok(panel.requests[0].url.endsWith('/api/status'));
});

test('a pending identity probe does not send a liveness heartbeat', async (t) => {
  const panel = bridgePanel(t, () => {}, { health: null });
  panel.tick();
  await new Promise(setImmediate);
  assert.equal(panel.requests.length, 1);
  assert.ok(panel.requests[0].url.endsWith('/api/status'));
});

test('legacy bridge status remains compatible without inventing build identity', async (t) => {
  assert.equal(await bridgeStatus(t, (xhr) => {
    xhr.status = 200; xhr.responseText = '{"jobs":[]}'; xhr.onload();
  }, { health: { sim: { connected: true }, link: { connected: false } } }), 'connected');
});

function bootstrap() {
  const html = readFileSync(`${__dirname}/../PackageSources/html_ui/InGamePanels/SimPilotLink/SimPilotLink.html`, 'utf8');
  const source = html.match(/<script type="text\/javascript">([\s\S]*?)<\/script>/)[1];
  const rows = Object.fromEntries(['spl-start', 'spl-build', 'spl-bridge'].map((id) => [id, { textContent: '' }]));
  const timers = new Map();
  const events = {};
  const window = { addEventListener(name, callback) { events[name] = callback; } };
  runInNewContext(source, {
    window, document: { getElementById: (id) => rows[id] },
    setTimeout(fn) { timers.set(1, fn); return 1; }, clearTimeout(id) { timers.delete(id); },
  });
  assert.ok(html.indexOf('id="spl-bridge"') < html.indexOf('src="link.js"'), 'markup must exist before the bundle runs');
  return { rows, timers, events, window };
}

test('bootstrap reports a missing bundle without relying on the bundle', () => {
  const state = bootstrap();
  state.window.simpilotLinkLoadFailed();
  assert.match(state.rows['spl-start'].textContent, /could not load/);
  assert.equal(state.rows['spl-bridge'].textContent, 'panel script failed');
});

test('bootstrap reports parse failures and clears its watchdog once the bundle starts', () => {
  const state = bootstrap();
  state.events.error({ filename: 'coui://html_ui/InGamePanels/SimPilotLink/link.js', message: 'Unexpected token' });
  assert.equal(state.rows['spl-start'].textContent, 'Unexpected token');
  state.window.simpilotLinkStarted('test-build');
  assert.equal(state.rows['spl-build'].textContent, 'test-build');
  assert.equal(state.rows['spl-start'].textContent, 'running');
  assert.equal(state.timers.size, 0);
});

test('bootstrap detects a bundle that never reaches startup', () => {
  const state = bootstrap();
  state.timers.get(1)();
  assert.match(state.rows['spl-start'].textContent, /did not start/);
});

test('the panel build is deterministic and its manifest hashes the actual three assets', () => {
  const cwd = path.resolve(__dirname, '..');
  const build = () => {
    const result = spawnSync(process.execPath, ['build.mjs'], { cwd, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return JSON.parse(readFileSync(path.join(cwd, 'PackageSources/panel-assets.json'), 'utf8'));
  };
  const first = build();
  assert.match(first.buildId, /^[0-9a-f]{12}$/);
  assert.equal(first.files.length, 3);
  for (const asset of first.files) {
    const actual = createHash('sha256').update(readFileSync(path.join(cwd, 'PackageSources/html_ui', asset.path))).digest('hex');
    assert.equal(asset.sha256, actual);
  }
  assert.deepEqual(build(), first);
});

// MSFS's script engine (Coherent) fails to parse `!await x` and `a || await x` ("Unexpected identifier"), and esbuild
// removes the parentheses that would hide them, so such code must never reach the shipped script.
test('the shipped panel script has no await after an operator', () => {
  for (const file of ['link', 'charts']) {
    const source = readFileSync(`${__dirname}/../src/${file}.ts`, 'utf8');
    const code = transformSync(source, { loader: 'ts', format: 'iife', target: 'es2017' }).code;
    assert.doesNotMatch(code, /(!|&&|\|\||\?) ?await\b/, `${file}: await directly after an operator`);
  }
});
