import { logoDataUri } from './logo.js';

// The page the launcher opens in its own window (and what http://localhost:8386 shows on the PC).
// It lives inside a template literal: keep backticks, ${ and backslashes out of the HTML and script.
const faq: [string, string][] = [
  ["The iPad doesn't find the PC", "Check both are on the same Wi-Fi, not a guest network. On the iPad: Settings > Privacy > Local Network > SimPilot EFB on. Otherwise type the address from the Status page into the app under Settings > Bridge."],
  ['Windows Firewall asked something', 'Tick "Private networks" and click Allow. Windows may call it "Node.js JavaScript Runtime"; that is SimPilot Bridge. Missed it? Use Repair > Fix firewall.'],
  ['MSFS says waiting', 'Start MSFS 2024 and load into a flight. The bridge connects by itself; no setting is needed.'],
  ['Do I need the chart panel?', "No. Weather, SimBrief and VATSIM work without it. The panel only sends the sim's own charts to the iPad."],
  ['Charts stay on exporting', "Keep the SimPilot Link panel open in the sim's toolbar and the sim window visible. Exports retry up to three times."],
  ['Does it slow down the sim?', 'Barely. It reads position 10 times a second over SimConnect and does nothing else unless the iPad asks.'],
  ['How do I update?', 'Click Install update when it appears. The bridge downloads the new version and restarts by itself.'],
];

const nav = (view: string, label: string, icon: string, on = false) =>
  `<button type="button" class="nav${on ? ' on' : ''}" data-view="${view}"><svg width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5">${icon}</svg>${label}</button>`;

const act = (id: string, title: string, text: string, label: string, danger = false) =>
  `<div class="row act"><div><b>${title}</b><small>${text}</small></div><button class="ghost${danger ? ' danger' : ''}" type="button" data-act="${id}">${label}</button></div>`;

export const appPage = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SimPilot Bridge</title><link rel="icon" href="${logoDataUri}">
<style>
:root{--frame:#22252B;--panel:#2B2E34;--line:#3A3D44;--hover:#2E3138;--fg:#fff;--fg2:#9EA3AB;--fg3:#6B7079;
--ok:#2FB24F;--btn:#3D8BFF;--warn:#E8913A;--bad:#ff6b6b;
--sans:Inter,-apple-system,"Segoe UI",system-ui,sans-serif;--mono:ui-monospace,Consolas,monospace;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--frame);color:var(--fg);font:14px/1.4 var(--sans)}
.app{min-height:100vh;display:flex;flex-direction:column}
.top{display:flex;align-items:center;gap:14px;height:52px;padding:0 18px;flex:none}
.brand{display:flex;align-items:center;gap:9px;font-weight:600}
.brand img{width:24px;height:24px;border-radius:6px}
.pick{border:1px solid var(--line);border-radius:8px;padding:6px 12px;font-weight:500}
.pick span{color:var(--fg2);font-weight:400;font-size:13px;margin-left:6px}
.conn{margin-left:auto;display:flex;align-items:center;gap:8px;color:var(--fg2);font-size:13px}
.dot{width:7px;height:7px;border-radius:50%;background:var(--ok);flex:none}.dot.off{background:var(--fg3)}.dot.busy{background:var(--btn)}
.body{display:grid;grid-template-columns:220px 1fr;gap:8px;padding:0 10px 10px;flex:1;min-height:0}
@media (max-width:720px){.body{grid-template-columns:1fr}.side{display:none}}
.side{display:flex;flex-direction:column;gap:2px;padding-top:4px}
.nav{display:flex;align-items:center;gap:11px;padding:9px 12px;border-radius:8px;color:var(--fg2);background:none;border:0;font:inherit;text-align:left;cursor:pointer;width:100%}
.nav.on{background:var(--hover);color:var(--fg)}.nav:not(.on):hover{color:var(--fg)}
.me{margin-top:auto;display:flex;align-items:center;gap:10px;padding:12px}
.me img{width:30px;height:30px;border-radius:7px}.me small{display:block;color:var(--fg2);font-size:12px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:26px 30px;min-width:0;overflow:auto}
.head{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
h1{font-size:21px;font-weight:600;margin:0 auto 0 0;letter-spacing:-.01em}
h2{font-size:13px;font-weight:500;color:var(--fg2);margin:26px 0 10px}.panel>h2:first-of-type{margin-top:0}
.lede{color:var(--fg2);margin:18px 0 26px}
button{font:inherit}button:focus-visible,summary:focus-visible{outline:2px solid var(--ok);outline-offset:2px}
.ghost{font-size:13.5px;color:var(--fg2);background:none;border:1px solid var(--line);border-radius:8px;padding:8px 14px;cursor:pointer}
.ghost:hover{color:var(--fg);border-color:#4a4e56}.ghost.danger{color:var(--bad);border-color:#5a3236}
.primary{font-size:14px;font-weight:500;color:#fff;background:var(--btn);border:0;border-radius:8px;padding:8px 16px;cursor:pointer}
.rows{border:1px solid var(--line);border-radius:10px;overflow:hidden}
.row{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:14px;padding:15px 18px;border-top:1px solid var(--line)}
.row:first-child{border-top:0}.row.act{grid-template-columns:1fr auto}
.row b{font-weight:500;display:block}.row small{color:var(--fg2);font-size:13px}
.num{font-family:var(--mono);font-size:12.5px;color:var(--fg2)}
.empty{padding:18px;color:var(--fg2)}
.addr{margin-top:22px;display:flex;align-items:center;gap:10px;flex-wrap:wrap;color:var(--fg2);font-size:13.5px}
.addr code{font-family:var(--mono);color:var(--fg);background:var(--hover);border:1px solid var(--line);border-radius:7px;padding:6px 10px}
.eye{background:none;border:1px solid var(--line);border-radius:7px;color:var(--fg2);width:32px;height:32px;display:grid;place-items:center;cursor:pointer}
.eye:hover{color:var(--fg)}.eye .c{display:none}.eye[aria-pressed="true"] .o{display:none}.eye[aria-pressed="true"] .c{display:block}
.foot{margin-top:28px;padding-top:18px;border-top:1px solid var(--line);display:flex;align-items:center;gap:10px;color:var(--fg2);font-size:13.5px}
.sw{appearance:none;width:30px;height:18px;border-radius:9px;background:var(--btn);position:relative;margin:0;cursor:pointer}
.sw::after{content:"";position:absolute;top:3px;left:15px;width:12px;height:12px;border-radius:50%;background:#fff;transition:left .15s}
.sw:not(:checked){background:var(--line)}.sw:not(:checked)::after{left:3px;background:var(--fg2)}
.log{margin:0;background:var(--frame);border:1px solid var(--line);border-radius:10px;padding:16px 18px;font:12.5px/1.75 var(--mono);color:var(--fg2);overflow:auto;max-height:60vh;white-space:pre-wrap}
.log .t{color:var(--fg3);margin-right:10px}.log .w{color:var(--warn)}.log .e{color:var(--bad)}
.qa{border-top:1px solid var(--line)}.qa:first-child{border-top:0}
.qa summary{list-style:none;cursor:pointer;padding:15px 18px;font-weight:500;display:flex;justify-content:space-between;gap:12px}
.qa summary::-webkit-details-marker{display:none}.qa summary::after{content:"+";color:var(--fg2);font-weight:400}.qa[open] summary::after{content:"-"}
.qa p{margin:0;padding:0 18px 16px;color:var(--fg2);line-height:1.6;max-width:65ch}
#toast{margin-top:18px;min-height:20px;color:var(--fg2);font-size:13.5px}
#stopped{position:fixed;inset:0;background:var(--frame);display:none;place-items:center;text-align:center;color:var(--fg2)}
#host{color:var(--fg);font-size:14px;font-weight:500}
#stopped b{display:block;color:var(--fg);font-size:18px;margin-bottom:6px}
</style>
<div class="app">
  <div class="top">
    <div class="brand"><img src="${logoDataUri}" alt="">SimPilot Bridge</div>
    <div class="pick"><span id="host" style="margin:0"></span><span class="ip" id="topip"></span></div>
    <div class="conn"><span class="dot off" id="conndot"></span><span id="conntext">Starting</span></div>
  </div>
  <div class="body">
    <aside class="side">
      ${nav('status', 'Status', '<rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/><rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/>', true)}
      ${nav('charts', 'Charts', '<rect x="3" y="2" width="10" height="12" rx="1.5"/><path d="M6 6h4M6 9h4"/>')}
      ${nav('log', 'Log', '<path d="M3 4h10M3 8h10M3 12h6"/>')}
      ${nav('repair', 'Repair', '<path d="M10.5 2.5a3 3 0 0 0-3.7 3.9L2.5 10.7l2.8 2.8 4.3-4.3a3 3 0 0 0 3.9-3.7l-1.8 1.8-2-.5-.5-2Z"/>')}
      ${nav('help', 'Help', '<circle cx="8" cy="8" r="6"/><path d="M6.3 6.3a1.8 1.8 0 1 1 2.4 1.7c-.5.2-.7.6-.7 1.1M8 11.2v.1"/>')}
      <div class="me"><img src="${logoDataUri}" alt=""><div>Version <span id="ver">-</span><small id="newver"></small></div></div>
    </aside>
    <main class="panel" data-page="status">
      <div class="head"><h1>Status</h1><button class="ghost" type="button" data-go="log">Open log</button><button class="primary" type="button" id="install" hidden>Install update</button></div>
      <p class="lede" id="lede">Starting the bridge...</p>
      <div class="rows">
        <div class="row"><span class="dot off" id="d-ipad"></span><div><b>iPad</b><small id="t-ipad"></small></div></div>
        <div class="row"><span class="dot off" id="d-sim"></span><div><b>MSFS 2024</b><small id="t-sim"></small></div></div>
        <div class="row"><span class="dot off" id="d-link"></span><div><b>Chart panel</b><small id="t-link"></small></div></div>
      </div>
      <div class="addr"><span>If the iPad doesn't find this PC, enter</span><code class="ip" id="addr"></code>
        <button type="button" class="eye" id="eye" aria-label="Hide address" aria-pressed="false">
          <svg class="o" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/></svg>
          <svg class="c" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/><path d="M2 2l12 12"/></svg>
        </button></div>
      <div class="foot"><input class="sw" type="checkbox" id="auto" aria-label="Start with Windows"><label for="auto">Start with Windows, hidden in the tray</label></div>
    </main>
    <main class="panel" data-page="charts" hidden>
      <div class="head"><h1>Charts</h1><button class="ghost" type="button" data-act="open-cache">Open cache folder</button><button class="primary" type="button" data-act="panel-install">Install chart panel</button></div>
      <p class="lede">Charts exported from the sim's Lido charts. The iPad asks for them when you open an airport.</p>
      <div class="rows" id="airports"></div>
      <div class="foot" id="cachesize"></div>
    </main>
    <main class="panel" data-page="log" hidden>
      <div class="head"><h1>Log</h1><button class="ghost" type="button" id="copylog">Copy</button></div>
      <p class="lede">What the bridge has been doing. Attach this when reporting a problem.</p>
      <pre class="log" id="log"></pre>
    </main>
    <main class="panel" data-page="repair" hidden>
      <div class="head"><h1>Repair</h1></div>
      <p class="lede">Fix common problems. None of these touch your flights or the iPad app.</p>
      <h2>Repair</h2>
      <div class="rows">
        ${act('firewall', 'Allow through Windows Firewall', "Adds the rule for private networks if the iPad can't connect. Windows asks for admin approval.", 'Fix firewall')}
        ${act('panel-repair', 'Repair chart panel', 'Copies SimPilot Link into MSFS 2024 again. Close the sim first.', 'Repair')}
        ${act('clear-cache', 'Clear chart cache', 'Deletes exported charts. They export again when needed.', 'Clear cache')}
      </div>
      <h2>Uninstall</h2>
      <div class="rows">
        ${act('uninstall', 'Uninstall SimPilot Bridge', 'Removes autostart, the firewall rule and cached charts, then closes. Delete the SimPilot for PC folder to finish. Remove the chart panel by deleting simpilot-link from the sim\'s Community folder.', 'Uninstall', true)}
      </div>
    </main>
    <main class="panel" data-page="help" hidden>
      <div class="head"><h1>Help</h1></div>
      <p class="lede">Answers to the questions people ask most.</p>
      <div class="rows">${faq.map(([q, a]) => `<details class="qa"><summary>${q}</summary><p>${a}</p></details>`).join('')}</div>
    </main>
  </div>
  <div id="toast" role="status" style="padding:0 20px 14px"></div>
</div>
<div id="stopped"><div><b>SimPilot Bridge stopped</b>You can close this window. Start SimPilot Bridge again from the Start menu or tray.</div></div>
<script>
var $ = function (s) { return document.querySelector(s); };
var hidden = false, info = null, misses = 0, view = 'status', bye = '';
function api(method, path) {
  return fetch(path, { method: method, headers: { 'x-simpilot-ui': '1' }, cache: 'no-store' }).then(function (r) {
    return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || 'failed'); return j; });
  });
}
function mask(t) { return hidden ? t.replace(/[0-9]/g, '\\u2022') : t; }
function toast(t) { $('#toast').textContent = t; }
function set(id, ok, text) { $('#d-' + id).className = 'dot' + (ok ? '' : ' off'); $('#t-' + id).textContent = text; }
function go(v) {
  view = v;
  document.querySelectorAll('.nav').forEach(function (n) { n.classList.toggle('on', n.dataset.view === v); });
  document.querySelectorAll('[data-page]').forEach(function (p) { p.hidden = p.dataset.page !== v; });
  toast(''); refresh();
}
document.querySelectorAll('.nav').forEach(function (n) { n.onclick = function () { go(n.dataset.view); }; });
document.querySelectorAll('[data-go]').forEach(function (b) { b.onclick = function () { go(b.dataset.go); }; });

function renderAddr() {
  var a = info && info.addresses[0] ? info.addresses[0].address : 'no network found';
  $('#addr').textContent = mask(a);
  $('#topip').textContent = info && info.addresses[0] ? mask(info.addresses[0].address.split(':')[0]) : '';
}
$('#eye').onclick = function () {
  hidden = !hidden; this.setAttribute('aria-pressed', hidden); this.setAttribute('aria-label', hidden ? 'Show address' : 'Hide address'); renderAddr();
};

function mb(b) { return b < 1048576 ? Math.max(1, Math.round(b / 1024)) + ' KB' : Math.round(b / 1048576) + ' MB'; }
function renderInfo() {
  if (!info) return;
  $('#host').textContent = info.hostname; $('#auto').checked = info.autostart; renderAddr();
  var box = $('#airports'); box.textContent = '';
  info.cache.airports.forEach(function (a) {
    var row = document.createElement('div'); row.className = 'row';
    row.innerHTML = '<span class="dot"></span><div><b></b><small></small></div><span class="num"></span>';
    row.querySelector('b').textContent = a.icao; row.querySelector('small').textContent = mb(a.bytes) + ' on disk';
    row.querySelector('.num').textContent = a.charts + ' charts'; box.appendChild(row);
  });
  if (!info.cache.airports.length) box.innerHTML = '<div class="empty">No charts yet. Open an airport in the iPad app with the chart panel running.</div>';
  $('#cachesize').textContent = info.cache.airports.length + ' airports, ' + mb(info.cache.bytes) + ' on disk';
}

function renderStatus(s) {
  misses = 0; $('#stopped').style.display = 'none';
  var apps = s.bridge.apps, sim = s.sim.connected, link = s.link.connected;
  $('#ver').textContent = s.bridge.version;
  $('#conndot').className = 'dot'; $('#conntext').textContent = 'Running';
  set('ipad', apps > 0, apps > 0 ? 'Connected' + (apps > 1 ? ' (' + apps + ' devices)' : '') : 'Waiting for the app');
  set('sim', sim, sim ? (s.sim.aircraftTitle || 'Connected') : 'Waiting. Start the sim.');
  set('link', link, link ? 'Connected' : 'Not connected (optional)');
  $('#lede').textContent = apps > 0 && sim ? 'Everything is connected. Leave this running while you fly.' : 'The bridge is running. Open SimPilot on your iPad and start MSFS 2024.';
}

function refresh() {
  api('GET', '/api/status').then(renderStatus, function () {
    if (++misses >= 3) { $('#conndot').className = 'dot off'; $('#conntext').textContent = 'Stopped'; if (bye) { $('#stopped').textContent = bye; $('#stopped').style.display = 'grid'; } else { $('#stopped').style.display = 'grid'; try { window.close(); } catch (e) {} } }
  });
  if (view === 'status' || view === 'charts') api('GET', '/bridge/info').then(function (i) { info = i; renderInfo(); }, function () {});
  if (view === 'log') api('GET', '/api/diagnostics').then(function (d) {
    var out = $('#log'), stick = out.scrollTop + out.clientHeight >= out.scrollHeight - 8; out.textContent = '';
    d.entries.forEach(function (e) {
      var line = document.createElement('div'), t = document.createElement('span'), m = document.createElement('span');
      t.className = 't'; t.textContent = e.time.slice(11, 19); m.textContent = '[' + e.scope + '] ' + e.message;
      if (e.level === 'warn') m.className = 'w'; if (e.level === 'error') m.className = 'e';
      line.appendChild(t); line.appendChild(m); out.appendChild(line);
    });
    if (stick) out.scrollTop = out.scrollHeight;
  }, function () {});
}
$('#copylog').onclick = function () {
  var text = $('#log').innerText, ok = function () { toast('Log copied.'); };
  (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(ok, function () {
    var r = document.createRange(); r.selectNodeContents($('#log')); var s = getSelection(); s.removeAllRanges(); s.addRange(r); toast('Press Ctrl+C to copy the selected log.');
  });
};

document.querySelectorAll('[data-act]').forEach(function (b) {
  var label = b.textContent, armed = false, timer = 0;
  b.onclick = function () {
    if (b.classList.contains('danger') && !armed) { armed = true; b.textContent = 'Click again to confirm'; timer = setTimeout(function () { armed = false; b.textContent = label; }, 4000); return; }
    clearTimeout(timer); armed = false; b.textContent = label; b.disabled = true; toast('Working...');
    api('POST', '/bridge/manage/' + b.dataset.act).then(function (r) { if (b.dataset.act === 'uninstall') bye = r.message; toast(r.message); refresh(); }, function (e) { toast(e.message); }).then(function () { b.disabled = false; });
  };
});
$('#auto').onchange = function () {
  var on = this.checked, box = this;
  api('POST', '/bridge/manage/' + (on ? 'autostart-on' : 'autostart-off')).then(function (r) { toast(r.message); }, function (e) { box.checked = !on; toast(e.message); });
};

function checkUpdate() {
  api('GET', '/bridge/update').then(function (u) {
    $('#newver').textContent = u.available ? u.latest + ' available' : 'Up to date';
    $('#newver').style.color = u.available ? 'var(--warn)' : '';
    $('#install').hidden = !(u.available && u.canInstall);
  }, function () {});
}
$('#install').onclick = function () {
  var b = this; b.disabled = true; toast('Downloading the update...');
  api('POST', '/bridge/update').then(function () {
    toast('Installing. SimPilot Bridge reopens by itself in a few seconds.'); setTimeout(function () { try { window.close(); } catch (e) {} }, 3000);
  }, function (e) { b.disabled = false; toast('Update failed: ' + e.message); });
};

refresh(); checkUpdate(); setInterval(refresh, 2000); setInterval(checkUpdate, 1800000);
</script>`;
