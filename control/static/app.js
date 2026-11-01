// Cyber Circle control: live game state over server-sent events, the rest
// through the control server's JSON API.
const $ = (s, el = document) => el.querySelector(s);
const STATE_NAMES = { LOBBY: "WACHT OP SPELERS", INTRO: "INTRO", PLAYING: "BEZIG", SCOREBOARD: "SCOREBORD" };
const FLOOR_TILES = 13, PLACES = 18;       // T01-T13 around the robot, M1-M5 the mobile players (drones)
// a place as the screens show it: "T03" / "M2"
const label = t => t <= FLOOR_TILES ? `T${String(t).padStart(2, "0")}` : `M${t - FLOOR_TILES}`;
let live = { state: {}, nodes: [], events: [], master: {}, mode: "setup" };
const MODE_NAMES = { setup: "SETUP", closed: "GESLOTEN", open: "OPEN", paused: "PAUZE" };
const MODE_ACTIONS = {          // [target mode, label, confirm?]
  setup: [["closed", "🔒 Setup vergrendelen"]],
  closed: [["setup", "🔓 Setup ontgrendelen"], ["open", "▶ Start spel"]],
  open: [["paused", "⏸ Pauze"], ["closed", "■ Stop spel", "Het spel stoppen? Alle spelers gaan eruit."]],
  paused: [["open", "▶ Hervat"], ["closed", "■ Stop spel", "Het spel stoppen? Alle spelers gaan eruit."]],
};

async function api(method, path, body) {
  const r = await fetch(path, { method, headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body) });
  if (!r.ok) { alert(`${method} ${path}: ${r.status} ${await r.text()}`); throw new Error(r.status); }
  return r.json();
}

function esc(s) { return String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]); }

// ---------------------------------------------------------------- tabs
document.querySelectorAll("nav button").forEach(b => b.onclick = () => {
  document.querySelectorAll("nav button, .tab").forEach(e => e.classList.remove("active"));
  b.classList.add("active");
  $(`#tab-${b.dataset.tab}`).classList.add("active");
  ({ website: loadWebsite, texts: loadTexts, gamemasters: loadGamemasters, players: loadPlayers, questions: loadQuestions, ranking: loadRanking, tiles: loadTiles, settings: loadSettings })[b.dataset.tab]?.();
});

// ---------------------------------------------------------------- live
function connectLive() {
  const es = new EventSource("/api/live");
  es.onmessage = e => { live = JSON.parse(e.data); renderLive(); };
  es.onerror = () => { $("#status").textContent = "GEEN VERBINDING MET DE SERVER"; };
}

function renderLive() {
  const s = live.state || {};
  const st = s.state === "SCOREBOARD" && s.uitslag ? "UITSLAG" : STATE_NAMES[s.state] || (s.state ? s.state : "GEEN MASTER");
  $("#status").textContent = s.round && s.state !== "LOBBY" ? `${st}: ${String(s.round).toUpperCase()}` : st;
  $("#timer").textContent = s.timer || "";
  const master = live.master?.node ? `master: ${live.master.node}` : "geen master gekozen";
  const w = live.website || {};
  $("#links").innerHTML = `MQTT ${live.mqtt ? "✓" : "✗"} · <span class="${w.status === "down" ? "bad" : ""}">website ${
    w.status === "ok" ? "✓" : w.status === "down" ? "✗ OFFLINE" : "?"}</span> · ${esc(master)}`;
  if ($("#tab-website").classList.contains("active")) loadWebsite();
  $("#mode").textContent = MODE_NAMES[live.mode] || live.mode;
  $("#mode").className = `mode ${live.mode}`;
  $("#mode-buttons").innerHTML = (MODE_ACTIONS[live.mode] || []).map(([m, label, ask]) =>
    `<button data-mode="${m}" ${ask ? `data-ask="${esc(ask)}"` : ""} class="${m === "closed" && live.mode !== "setup" ? "danger" : ""}">${label}</button>`).join("");
  renderPlan(s);
  renderTiles(s);
  renderOnline();
  $("#events").innerHTML = (live.events || []).map(e =>
    `<li><span class="t">${esc(e.time)}</span><span style="color:${esc(e.color || "")}">${esc(e.text)}</span></li>`).join("");
  renderNodes();
  if ($("#tab-tiles").classList.contains("active")) { renderTileTable(); renderLayout(); }
}

// the live places: the floor tiles, then the mobile players (drones)
function renderTiles(s) {
  const floor = s.floor_tiles || FLOOR_TILES, count = s.tile_count || PLACES;
  const players = Object.fromEntries((s.players || []).map(p => [p.tile, p]));
  $("#tiles").innerHTML = tileCards(s, 1, floor);
  $("#mobile-tiles").innerHTML = tileCards(s, floor + 1, count);
  const n = (a, b) => Object.keys(players).filter(t => t >= a && t <= b).length;
  $("#tiles-count").textContent = `${n(1, floor)} / ${floor} spelers`;
  $("#mobile-count").textContent = `${n(floor + 1, count)} / ${count - floor} spelers · toewijzen bij Spelers`;
}

function tileCards(s, from, to) {
  const players = Object.fromEntries((s.players || []).map(p => [p.tile, p]));
  const pending = Object.fromEntries((s.pending || []).map(p => [p.tile, p]));
  let html = "";
  for (let t = from; t <= to; t++) {
    const p = players[t], inv = pending[t];
    const mobile = t > FLOOR_TILES ? " mobile" : "";
    if (p) {
      html += `<div class="tile playing${mobile} ${p.out ? "out" : ""}"><span class="no">${label(t)}</span>
        ${p.rank ? `<span class="rank">#${p.rank}</span>` : ""}
        <div class="name">${esc(p.name)}</div>
        <div class="hearts">${"♥".repeat(p.lives)}${"♡".repeat(Math.max(0, (p.max_lives || 0) - p.lives))}</div>
        <div class="score">${p.survived ?? 0} rondes overleefd${s.ranked && s.state === "PLAYING" ? ` · ${p.points ?? 0} punten deze ronde` : ""}${p.streak >= 2 ? ` · ${p.streak} op rij` : ""}</div>
        <div class="actions">
          <button class="small" data-tile="${t}" data-points="1">+1</button>
          <button class="small" data-tile="${t}" data-points="5">+5</button>
          <button class="small" data-tile="${t}" data-points="10">+10</button>
          <button class="small" data-tile="${t}" data-points="-5">−5</button>
          <button class="small" data-tile="${t}" data-lives="${p.lives - 1}" title="leven eraf">♥−</button>
          <button class="small" data-tile="${t}" data-lives="${p.lives + 1}" title="leven erbij">♥+</button>
          <button class="small" data-tile="${t}" data-act="revive" title="alle levens terug">Herstel</button>
          <button class="small" data-tile="${t}" data-act="attack" title="speler valt de robot aan">Aanval</button>
          <button class="small" data-tile="${t}" data-act="fire" title="robot draait en vuurt (show)">Robot vuurt</button>
          <button class="small danger" data-tile="${t}" data-act="leave">Verwijder</button></div></div>`;
    } else if (inv) {
      html += `<div class="tile${mobile}" style="border-color:${esc(inv.color)}"><span class="no">${label(t)}</span>
        <div class="name" style="color:${esc(inv.color)}">${esc(inv.name)}</div><div class="hint">wacht op activatie (4 iconen)</div>
        <div class="actions"><button class="small danger" data-tile="${t}" data-act="leave">Annuleer</button></div></div>`;
    } else if ((s.disabled || []).includes(t)) {
      html += `<div class="tile out${mobile}"><span class="no">${label(t)}</span><div class="name">BUITEN GEBRUIK</div></div>`;
    } else {
      html += `<div class="tile free${mobile}"><span class="no">${label(t)}</span><div class="name">VRIJ</div>
        ${mobile ? `<div class="hint">drone in de parking</div>` : ""}</div>`;
    }
  }
  return html;
}

$("#tiles").onclick = $("#mobile-tiles").onclick = e => {
  const b = e.target.closest("button[data-tile]");
  if (!b) return;
  const t = b.dataset.tile;
  if (b.dataset.points) return api("POST", `/api/tiles/${t}/points`, { points: Number(b.dataset.points) });
  if (b.dataset.lives) return api("POST", `/api/tiles/${t}/lives`, { lives: Number(b.dataset.lives) });
  if (b.dataset.act !== "leave" || confirm(`Speler van ${label(Number(t))} verwijderen?`))
    api("POST", `/api/tiles/${t}/${b.dataset.act}`);
};
document.querySelectorAll("[data-game]").forEach(b => b.onclick = () => api("POST", `/api/game/${b.dataset.game}`));
$("#mode-buttons").onclick = e => {
  const b = e.target.closest("button[data-mode]");
  if (b && (!b.dataset.ask || confirm(b.dataset.ask))) api("POST", "/api/mode", { mode: b.dataset.mode });
};

// the coming rounds: the randomizer fills the plan, the operator can choose
function renderPlan(s) {
  const types = s.round_types || [];
  const el = $("#plan");
  if (el.contains(document.activeElement)) return;      // don't disturb while editing
  el.innerHTML = (s.plan || []).map((p, i) => `<div class="slot ${p.forced ? "forced" : ""}">
      <div class="n">${i === 0 ? "VOLGENDE" : `+${i}`} · ${p.forced ? "gekozen" : "willekeurig"}</div>
      <select data-slot="${i}"><option value="">willekeurig</option>
        ${types.map(t => `<option value="${t.type}" ${p.forced && p.type === t.type ? "selected" : ""}>${esc(t.title)}</option>`).join("")}
      </select> ${p.forced ? "" : `<b>${esc(p.title)}</b> <span class="chance" title="kans bij het loten">${Math.round((p.chance ?? 1) * 100)}%</span>`}
      ${p.type === "quiz" && p.forced ? `<input data-slot="${i}" placeholder="categorieën (komma's)" value="${esc((p.options?.categories || []).join(", "))}">` : ""}
    </div>`).join("") + `<button class="small" id="plan-random">alles willekeurig</button>`;
}
$("#plan").onchange = e => {
  const slot = Number(e.target.dataset.slot);
  if (e.target.matches("select")) return api("POST", "/api/plan", { slot, round: e.target.value });
  if (e.target.matches("input")) {
    const cats = e.target.value.split(",").map(c => c.trim()).filter(Boolean);
    api("POST", "/api/plan", { slot, round: "quiz", options: cats.length ? { categories: cats } : {} });
  }
};
$("#plan").onclick = e => { if (e.target.id === "plan-random") api("POST", "/api/plan/random"); };

// ---------------------------------------------------------------- processes
function renderNodes() {
  const tbody = $("#nodes tbody");
  tbody.innerHTML = (live.nodes || []).map(n => {
    const isMaster = live.master?.node === n.id;
    return `<tr class="${isMaster ? "master" : ""}"><td>${esc(n.id)}</td><td>${esc(isMaster ? "MASTER" : n.role)}</td>
      <td>${esc(n.host)}${n.port ? ":" + n.port : ""}</td><td>${esc((n.screens || []).join(", ") || "-")}</td>
      <td><span class="dot ${n.online ? "on" : ""}"></span> ${n.online ? "online" : "offline"}${n.fps ? ` · ${n.fps} fps` : ""}</td>
      <td>${isMaster || !n.online ? "" : `<button class="small" data-master="${esc(n.id)}">Maak master</button>`}</td></tr>`;
  }).join("") || `<tr><td colspan="6" class="hint">Nog geen processen gezien.</td></tr>`;
  $("#master").textContent = live.master?.node
    ? `Master: ${live.master.node} (${live.master.host}:${live.master.port}) sinds ${live.master.since || "?"}`
    : "Nog geen master gekozen.";
}
$("#nodes").onclick = e => {
  const b = e.target.closest("button[data-master]");
  if (b && confirm(`${b.dataset.master} wordt de master. De schermen verbinden opnieuw.`))
    api("POST", "/api/master", { node: b.dataset.master });
};

// ---------------------------------------------------------------- tiles: places and physical tiles
let tileRows = [];
async function loadTiles() {
  tileRows = (await api("GET", "/api/tiles")).tiles;
  renderTileTable();
  renderLayout();
}

// the circle in the venue, like a clock seen from above: the entrance at 6, T01 at t01_clock
function renderLayout() {
  const h = live.t01_clock || 12;
  const sel = $("#t01-clock");
  if (!sel.options.length)
    sel.innerHTML = Array.from({ length: 24 }, (_, i) => (i + 1) / 2)
      .map(v => `<option value="${v}">${Number.isInteger(v) ? v : Math.floor(v) + "½"}</option>`).join("");
  if (document.activeElement !== sel) sel.value = String(h);
  const pt = (a, r) => [Math.cos(a) * r, Math.sin(a) * r];
  let svg = `<circle r="110" fill="none" stroke="var(--dim)"/><line x1="-22" y1="110" x2="22" y2="110" stroke="var(--orange)" stroke-width="6"/>
    <text y="104" text-anchor="middle" fill="var(--orange)" font-size="11">INGANG</text>
    <circle r="16" fill="var(--panel)" stroke="var(--teal)"/><text y="4" text-anchor="middle" fill="var(--teal)" font-size="8">ROBOT</text>`;
  for (let t = 1; t <= FLOOR_TILES; t++) {
    const [x, y] = pt(-Math.PI / 2 + h * Math.PI / 6 + 2 * Math.PI * (t - 1) / FLOOR_TILES, 78);
    svg += `<line x2="${x}" y2="${y}" stroke="var(--line)"/><circle cx="${x}" cy="${y}" r="13" fill="${t === 1 ? "var(--amber)" : "var(--panel)"}" stroke="var(--orange)"/>
      <text x="${x}" y="${y + 3.5}" text-anchor="middle" font-size="9" fill="${t === 1 ? "var(--bg)" : "var(--cream)"}">${label(t)}</text>`;
  }
  $("#layout-plan").innerHTML = svg;
}
$("#t01-clock").onchange = async e => {
  await api("PUT", "/api/layout", { t01_clock: Number(e.target.value) });
};
function renderTileTable() {
  const devices = live.devices || [];
  const online = Object.fromEntries(devices.map(d => [d.device, d.online]));
  const placed = new Set(tileRows.map(t => t.device).filter(Boolean));
  $("#tile-table tbody").innerHTML = tileRows.map(t => {
    const opts = new Set([...devices.map(d => d.device), ...(t.device ? [t.device] : [])]);
    const head = t.number === FLOOR_TILES + 1 ? `<tr><td colspan="4" class="section">Handtegels van mobiele spelers (M1–M5: drones in het spel)</td></tr>` : "";
    return `${head}<tr><td><span class="no" style="background:var(--teal);color:var(--bg);padding:0 6px">${label(t.number)}</span></td>
      <td><select data-number="${t.number}" data-field="device" ${live.mode !== "setup" && t.enabled ? "disabled title='setup vergrendeld: eerst buiten gebruik zetten'" : ""}><option value="">— geen —</option>
        ${[...opts].sort().map(d => `<option ${d === t.device ? "selected" : ""}>${esc(d)}</option>`).join("")}</select></td>
      <td>${t.device ? `<span class="dot ${online[t.device] ? "on" : ""}"></span> ${online[t.device] ? "online" : "offline"}` : "-"}</td>
      <td><button class="small ${t.enabled ? "" : "danger"}" data-number="${t.number}" data-field="enabled">
        ${t.enabled ? "in gebruik" : "BUITEN GEBRUIK"}</button></td></tr>`;
  }).join("");
  const free = devices.filter(d => !placed.has(d.device));
  $("#free-devices").innerHTML = free.map(d => `<li><span class="dot ${d.online ? "on" : ""}"></span> ${esc(d.device)}
    <span class="hint">${esc(d.fw || "")}</span></li>`).join("") || `<li class="hint">Geen.</li>`;
}
$("#tile-table").onchange = async e => {
  const sel = e.target.closest("select[data-field=device]");
  if (!sel) return;
  await api("PUT", `/api/tiles/${sel.dataset.number}`, { device: sel.value || null });
  loadTiles();
};
$("#tile-table").onclick = async e => {
  const b = e.target.closest("button[data-field=enabled]");
  if (!b) return;
  const t = tileRows.find(r => r.number == b.dataset.number);
  if (t.enabled && !confirm(`${label(t.number)} buiten gebruik zetten? Een speler die erop staat gaat eruit.`)) return;
  await api("PUT", `/api/tiles/${t.number}`, { enabled: !t.enabled });
  loadTiles();
};

// ---------------------------------------------------------------- website (registrations)
const ago = s => s === null || s === undefined ? "nog niet" : s < 60 ? `${s} s geleden` : s < 3600 ? `${Math.round(s / 60)} min geleden` : `${Math.round(s / 3600)} u geleden`;
async function loadWebsite() {
  const w = await api("GET", "/api/website");
  const up = w.status === "ok", down = w.status === "down";
  $("#website").innerHTML = `<div class="site ${up ? "up" : down ? "down" : ""}">
      <div class="big">${up ? "✓ BEREIKBAAR" : down ? "✗ NIET BEREIKBAAR" : "… NOG NIET GECONTROLEERD"}</div>
      ${down ? `<div class="bad">Nieuwe registraties komen niet binnen. ${esc(w.error)}</div>` : ""}
      <table>
        <tr><td>Health endpoint</td><td>${esc(w.url)}${w.mock ? ` <span class="hint">(mock: nog geen echte website ingesteld, --website=URL)</span>` : ""}</td></tr>
        <tr><td>Laatst gecontroleerd</td><td>${ago(w.checked_ago)} (elke ${w.interval} s)${w.latency_ms !== null ? ` · ${w.latency_ms} ms` : ""}</td></tr>
        <tr><td>Laatst bereikbaar</td><td>${ago(w.last_ok_ago)}</td></tr>
        <tr><td>Laatste registratie binnen</td><td>${ago(w.last_sync_ago)} · ${w.syncs} sinds de start</td></tr>
      </table>
      ${w.mock ? `<div class="row"><button data-mock="${w.mock_up ? "0" : "1"}">${w.mock_up ? "Mock: zet website uit (test)" : "Mock: zet website aan"}</button></div>` : ""}
    </div>`;
  $("#website-history").innerHTML = w.history.map(h => `<li><span class="t">${esc(h.time)}</span>
    <span class="${h.ok ? "" : "bad"}">${h.ok ? `✓ ${h.ms} ms` : `✗ ${esc(h.error)}`}</span></li>`).join("");
}
$("#website").onclick = async e => {
  const b = e.target.closest("button[data-mock]");
  if (b) { await api("POST", "/api/website/mock", { up: b.dataset.mock === "1" }); loadWebsite(); }
};

// ---------------------------------------------------------------- texts
const GAME_ORDER = ["quiz", "cyclone", "reaction", "simon", "zwarte_piet", "rhythm"];

async function loadTexts() {
  const { defaults, values } = await api("GET", "/api/texts");
  if (!Object.keys(defaults).length) {
    $("#texts").innerHTML = `<p class="hint">Nog geen master verbonden: de standaardteksten komen van het spel.</p>`;
    return;
  }
  const field = (key, label, rows) => {
    const v = values[key] ?? "", d = defaults[key] ?? "";
    const input = rows
      ? `<textarea data-key="${key}" rows="${rows}" placeholder="${esc(d)}" class="${v ? "changed" : ""}">${esc(v)}</textarea>`
      : `<input data-key="${key}" placeholder="${esc(d)}" value="${esc(v)}" class="${v ? "changed" : ""}">`;
    return `<label><span>${label} <a href="#" data-default="${key}" class="hint">standaard</a></span>${input}</label>`;
  };
  const games = GAME_ORDER.filter(t => defaults["title." + t] !== undefined);
  $("#texts").innerHTML =
    `<fieldset><legend>Oproepen en meedoen</legend>
      ${field("cta", "Oproepen (één per regel, ze wisselen elkaar af)", 6)}
      ${field("join_steps", "Hoe doe je mee? (overzichtsscherm)", 6)}
      ${field("join_text", "Op het scherm van een vrije tegel", 0)}</fieldset>` +
    games.map(t => `<fieldset><legend>${esc(defaults["title." + t])}</legend>
      ${field("title." + t, "Naam", 0)}${field("rules." + t, "Uitleg (intro, overzichtsscherm)", 6)}</fieldset>`).join("");
  $("#texts-msg").textContent = "";
}
$("#texts").oninput = e => e.target.classList.toggle("changed", e.target.value.trim() !== "");
$("#texts").onclick = e => {
  const a = e.target.closest("a[data-default]");
  if (!a) return;
  e.preventDefault();
  const el = $(`#texts [data-key="${a.dataset.default}"]`);
  el.value = "";
  el.classList.remove("changed");
};
$("#texts-save").onclick = async () => {
  const values = {};
  document.querySelectorAll("#texts [data-key]").forEach(el => { if (el.value.trim()) values[el.dataset.key] = el.value; });
  await api("PUT", "/api/texts", values);
  await loadTexts();
  $("#texts-msg").textContent = "Opgeslagen ✓";
};
$("#texts-reset").onclick = async () => {
  if (!confirm("Alle teksten terug naar de standaard?")) return;
  await api("PUT", "/api/texts", {});
  await loadTexts();
  $("#texts-msg").textContent = "Alles standaard ✓";
};

// ---------------------------------------------------------------- gamemasters
function renderOnline() {
  const on = live.gamemasters_online || [];
  $("#gm-online").innerHTML = on.map(g => `<span class="gm" style="border-color:${esc(g.color)}">
      <span class="swatch" style="background:${esc(g.color)}"></span> ${esc(g.name)} <span class="hint">sinds ${esc(g.since)}</span></span>`).join("")
    || `<span class="hint">Niemand.</span>`;
  if ($("#tab-gamemasters").classList.contains("active")) renderGamemasters();
}
let gmRows = [];
async function loadGamemasters() {
  gmRows = await api("GET", "/api/gamemasters");
  renderGamemasters();
}
function renderGamemasters() {
  const on = new Set((live.gamemasters_online || []).map(g => g.id));
  const body = $("#gamemasters tbody");
  if (body.contains(document.activeElement)) return;      // (editing)
  body.innerHTML = gmRows.map(g => `<tr><td><input data-gm="${g.id}" data-field="name" value="${esc(g.name)}"></td>
    <td><input type="color" data-gm="${g.id}" data-field="color" value="${esc(g.color)}"></td>
    <td>${on.has(g.id) ? `<span class="dot on"></span> ingelogd` : `<span class="hint">-</span>`}</td>
    <td><button class="small danger" data-gm-del="${g.id}">Verwijder</button></td></tr>`).join("")
    || `<tr><td colspan="4" class="hint">Nog geen gamemasters.</td></tr>`;
}
$("#add-gm").onsubmit = async e => {
  e.preventDefault();
  const f = e.target;
  await api("POST", "/api/gamemasters", { name: f.name.value, color: f.color.value });
  f.name.value = "";
  loadGamemasters();
};
$("#gamemasters").onchange = async e => {
  const i = e.target.closest("input[data-gm]");
  if (!i) return;
  const row = gmRows.find(g => g.id == i.dataset.gm);
  row[i.dataset.field] = i.value;
  await api("PUT", `/api/gamemasters/${row.id}`, { name: row.name, color: row.color });
};
$("#gamemasters").onclick = async e => {
  const b = e.target.closest("button[data-gm-del]");
  if (b && confirm("Deze gamemaster verwijderen?")) { await api("DELETE", `/api/gamemasters/${b.dataset.gmDel}`); loadGamemasters(); }
};

// ---------------------------------------------------------------- players
// assignment colours: the tile lights up in it so the visitor finds it; a
// colour no invited player has right now
const ASSIGN_COLORS = ["#ff8800", "#33ccff", "#ff44cc", "#88ff00", "#ffee00", "#aa55ff", "#ff3344", "#00ffcc", "#ffffff"];
function nextColor() {
  const used = new Set((live.state?.pending || []).map(p => p.color.toLowerCase()));
  return ASSIGN_COLORS.find(c => !used.has(c)) || ASSIGN_COLORS[0];
}
async function loadPlayers() {
  const rows = await api("GET", `/api/players?search=${encodeURIComponent($("#player-search").value)}`);
  $("#players tbody").innerHTML = rows.map(p => `<tr><td>${p.id}</td><td>${esc(p.name)}</td>
    <td>${esc(p.card || "-")}</td><td>${p.age || "-"}</td>
    <td>${p.best ?? "-"}</td><td>${p.plays}</td>
    <td><input type="color" data-color="${p.id}" value="${nextColor()}" title="de tegel licht op in deze kleur">
      <select data-pid="${p.id}"><option value="">tegel…</option><option value="0">vrije vloertegel</option>
      <optgroup label="Vloertegels">${Array.from({ length: FLOOR_TILES }, (_, i) => `<option value="${i + 1}">${label(i + 1)}</option>`).join("")}</optgroup>
      <optgroup label="Mobiel (drone)">${Array.from({ length: PLACES - FLOOR_TILES }, (_, i) =>
        `<option value="${FLOOR_TILES + i + 1}">${label(FLOOR_TILES + i + 1)}</option>`).join("")}</optgroup>
    </select></td></tr>`).join("");
}
$("#player-search").oninput = loadPlayers;
$("#players").onchange = async e => {
  const sel = e.target.closest("select[data-pid]");
  if (!sel || sel.value === "") return;
  const color = $(`input[data-color="${sel.dataset.pid}"]`).value;
  await api("POST", `/api/players/${sel.dataset.pid}/assign`, { tile: Number(sel.value), color });
  sel.value = "";
};
$("#add-player").onsubmit = async e => {
  e.preventDefault();
  const f = e.target;
  await api("POST", "/api/players", { name: f.name.value, age: Number(f.age.value || 0) });
  f.name.value = ""; f.age.value = "";
  loadPlayers();
};

// ---------------------------------------------------------------- questions
let questions = [];
async function loadQuestions() {
  questions = await api("GET", "/api/questions/all");
  $("#questions tbody").innerHTML = questions.map(q => `<tr><td>${q.id}</td><td>${esc(q.category)}</td>
    <td>${q.min_age}–${q.max_age}</td><td>${esc(q.question)}${q.video ? " 🎬" : ""}${q.image ? " 🖼" : ""}</td>
    <td>${q.active ? "ja" : "nee"}</td><td><button class="small" data-qid="${q.id}">Bewerk</button></td></tr>`).join("");
}
function openQuestion(q) {
  const f = $("#question-form");
  for (const el of f.elements) if (el.name) el.value = q[el.name] ?? el.defaultValue ?? "";
  $("#delete-question").style.display = q.id ? "" : "none";
  $("#question-dialog").showModal();
}
$("#questions").onclick = e => {
  const b = e.target.closest("button[data-qid]");
  if (b) openQuestion(questions.find(q => q.id == b.dataset.qid));
};
$("#csv-file").onchange = async e => {
  const file = e.target.files[0];
  if (!file) return;
  const r = await fetch("/api/questions/import", { method: "POST", headers: { "Content-Type": "text/csv" }, body: await file.text() });
  const res = await r.json();
  $("#csv-result").innerHTML = `<b>${esc(file.name)}</b>: ${res.added} toegevoegd, ${res.updated} bijgewerkt` +
    (res.errors.length ? `, ${res.errors.length} overgeslagen:<br>` + res.errors.map(x => `regel ${x.line}: ${esc(x.error)}`).join("<br>") : "");
  e.target.value = "";
  loadQuestions();
};
$("#new-question").onclick = () => openQuestion({ min_age: 0, max_age: 99, correct: 0, time: 0, active: 1, video_when: "before" });
$("#question-form").onsubmit = async e => {
  if (e.submitter?.value !== "save") return;
  const f = e.target, q = {};
  for (const el of f.elements) if (el.name && el.name !== "id") q[el.name] = el.value;
  for (const k of ["min_age", "max_age", "correct", "active"]) q[k] = Number(q[k]);
  q.time = Number(q.time); q.slug = q.slug || null;
  if (f.id.value) await api("PUT", `/api/questions/${f.id.value}`, q); else await api("POST", "/api/questions", q);
  loadQuestions();
};
$("#delete-question").onclick = async () => {
  const id = $("#question-form").id.value;
  if (id && confirm("Deze vraag verwijderen? (Of zet 'Actief' op nee.)")) {
    await api("DELETE", `/api/questions/${id}`);
    $("#question-dialog").close();
    loadQuestions();
  }
};

// ---------------------------------------------------------------- ranking
async function loadRanking() {
  const rows = await api("GET", "/api/ranking?limit=100");
  $("#ranking tbody").innerHTML = rows.map((r, i) =>
    `<tr><td>#${i + 1}</td><td>${esc(r.name)}</td><td>${r.best}</td><td>${r.plays}</td></tr>`).join("");
}

connectLive();

// ---------------------------------------------------------------- settings
const UNITS = { s: "s", ms: "ms" };

async function loadSettings() {
  const { schema, values } = await api("GET", "/api/settings");
  if (!schema.length) {
    $("#settings").innerHTML = `<p class="hint">Nog geen master verbonden: de instellingen komen van het spel.</p>`;
    return;
  }
  $("#settings").innerHTML = schema.map(g => `<fieldset data-group="${esc(g.group)}"><legend>${esc(g.title)}</legend>` +
    g.items.map(t => {
      const v = values[g.group]?.[t.key];
      return `<label title="standaard ${esc(t.default)}${UNITS[t.unit] || ""} (${t.min} – ${t.max})">
        <span>${esc(t.label)}</span>
        <input type="number" data-key="${esc(t.key)}" min="${t.min}" max="${t.max}" step="${t.step}"
          placeholder="${esc(t.default)}" value="${v ?? ""}" class="${v !== undefined ? "changed" : ""}">
        <em>${UNITS[t.unit] || ""}</em></label>`;
    }).join("") + `</fieldset>`).join("");
  $("#settings").oninput = e => e.target.classList.toggle("changed", e.target.value !== "");
  $("#settings-msg").textContent = "";
}

$("#settings-save").onclick = async () => {
  const values = {};
  document.querySelectorAll("#settings fieldset").forEach(f => {
    const g = {};
    f.querySelectorAll("input").forEach(i => {
      if (i.value === "") return;
      const v = Math.min(+i.max, Math.max(+i.min, +i.value));
      if (String(v) !== i.placeholder) g[i.dataset.key] = v;
    });
    if (Object.keys(g).length) values[f.dataset.group] = g;
  });
  await api("PUT", "/api/settings", values);
  await loadSettings();
  $("#settings-msg").textContent = "Opgeslagen ✓";
};

$("#settings-reset").onclick = async () => {
  if (!confirm("Alle instellingen terug naar de standaardwaarden?")) return;
  await api("PUT", "/api/settings", {});
  await loadSettings();
  $("#settings-msg").textContent = "Alles standaard ✓";
};
