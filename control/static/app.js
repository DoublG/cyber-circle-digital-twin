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
  ({ perf: startPerf, clients: startClients, recovery: renderRecovery, mqtt: startMqttLog, website: loadWebsite, sounds: renderSounds, texts: loadTexts, gamemasters: loadGamemasters, players: loadPlayers, questions: loadQuestions, ranking: loadRanking, tiles: loadTiles, settings: loadSettings })[b.dataset.tab]?.();
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
  if ($("#tab-sounds").classList.contains("active")) renderSounds();
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
  if ($("#tab-recovery").classList.contains("active")) renderRecovery();
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
    const display = n.role === "display";
    // a display node (a Pi): its screens and whether it is connected to the master; the master: which screens the Pis render
    const screens = esc((n.screens || []).join(", ") || "-")
      + (n.remote_screens?.length ? ` <span class="hint">(op de displays: ${esc(n.remote_screens.join(", "))}; ${n.displays || 0} verbonden)</span>` : "");
    const link = display ? (n.master ? ` · verbonden met ${esc(n.master)}` : ` · <b class="bad">wacht op de master</b>`) : "";
    return `<tr class="${isMaster ? "master" : ""}"><td>${esc(n.id)}</td><td>${esc(isMaster ? "MASTER" : display ? "DISPLAY" : n.role)}</td>
      <td>${esc(n.host)}${n.port ? ":" + n.port : ""}</td><td>${screens}</td>
      <td><span class="dot ${n.online ? "on" : ""}"></span> ${n.online ? "online" : "offline"}${n.fps ? ` · ${n.fps} fps` : ""}${link}${n.db_pending ? ` · <b class="bad">database: ${n.db_pending} writes waiting</b>` : ""}</td>
      <td>${isMaster || !n.online || display ? "" : `<button class="small" data-master="${esc(n.id)}">Maak master</button>`}</td></tr>`;
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

// ---------------------------------------------------------------- Herstel: the saved game state
const PHASES = { LOBBY: "lobby", INTRO: "uitleg van een ronde", PLAYING: "een ronde bezig", SCOREBOARD: "scorebord" };
function restartWould(cp) {
  const n = cp.round, people = cp.players.length + cp.invites.length;
  if (!people) return "Geen spel bezig: een herstart begint leeg.";
  if (cp.state === "LOBBY") return "Na een herstart: de spelers terug op hun tegel, de uitnodigingen opnieuw.";
  if (cp.state === "INTRO" || cp.state === "PLAYING")
    return `Ronde ${n} is bezig en telt nog niet. Na een herstart: het scorebord, dan ronde ${n} opnieuw vanaf de uitleg, met dezelfde levens.`;
  const changes = Object.entries(cp.pending_lives || {}).filter(([, d]) => d);
  if (changes.length) return `Einde van ronde ${n}: de levens veranderen zo (${changes.map(([t, d]) =>
    `${label(Number(t))} ${d > 0 ? "+1" : "−1"}`).join(", ")}). Na een herstart gebeurt dat meteen (ook exterminaties), dan ronde ${n + 1}.`;
  return `Na ronde ${n}. Na een herstart: het scorebord, dan ronde ${n + 1}.`;
}
function renderRecovery() {
  const info = live.checkpoint || {}, cp = info.data, s = live.state || {};
  const title = t => (s.round_types || []).find(r => r.type === t)?.title || t;
  if (!cp) {
    $("#recovery").className = "site";
    $("#recovery").innerHTML = `<div class="big">GEEN BEWAARDE STATUS</div><div>${info.cleared_ago != null
      ? `Gewist ${ago(Math.round(info.cleared_ago))}: de volgende start van het spel begint leeg.`
      : "Het spel heeft nog niets bewaard (nog geen spel met --control gestart)."}</div>`;
    ["#recovery-players tbody", "#recovery-invites", "#recovery-plan"].forEach(q => $(q).innerHTML = "");
  } else {
    const old = info.age > 3600;
    // in line with the game: the same players on the same tiles, the same round
    const liveTiles = (s.players || []).map(p => p.tile).sort().join(), cpTiles = cp.players.filter(p => !p.dead).map(p => p.tile).sort().join();
    const inLine = !s.state || (liveTiles === cpTiles && (s.round_number ?? cp.round) === cp.round);
    const behind = !inLine && info.age > 15;
    $("#recovery").className = `site ${old || behind ? "warn" : "up"}`;
    $("#recovery").innerHTML = `<div class="big">${old ? "TE OUD – EEN HERSTART BEGINT LEEG" : behind ? "LOOPT ACHTER OP HET SPEL" : "✓ BEWAARD"}</div>
      <div>${esc(old ? "Ouder dan een uur: het spel van gisteren." : restartWould(cp))}</div>
      <table>
        <tr><td>Laatst bewaard</td><td>${ago(Math.round(info.age))} (${new Date(cp.time * 1000).toLocaleTimeString("nl-BE")})</td></tr>
        <tr><td>Toestand</td><td>${esc(PHASES[cp.state] || cp.state)}${cp.round ? ` · ronde ${cp.round}` : ""}${cp.current?.type ? ` (${esc(title(cp.current.type))})` : ""}</td></tr>
        <tr><td>Spel in de database</td><td>${cp.game_id > 0 ? `#${cp.game_id}` : cp.game_id < 0 ? "nog niet op de server (wacht)" : "–"}</td></tr>
        <tr><td>Database</td><td>${esc(String(cp.db || "").slice(0, 12)) || "?"}</td></tr>
      </table>
      <div class="row"><button class="danger" id="recovery-clear">Vergeet bewaarde status</button>
        <span class="hint">De volgende start van het spel begint dan leeg (een lopend spel bewaart bij zijn volgende stap opnieuw).</span></div>`;
    $("#recovery-players tbody").innerHTML = cp.players.map(p => `<tr><td>${label(p.tile)}</td><td>${esc(p.name)}</td>
      <td class="hearts">${"♥".repeat(Math.max(p.lives, 0))}<span class="hint">${"♡".repeat(Math.max(p.max_lives - p.lives, 0))}</span></td>
      <td>${p.survived}</td><td>${p.dead ? `<span class="bad">geëxtermineerd – zijn spel eindigt</span>` : p.started || cp.state === "LOBBY" ? "speelt" : "wacht op de volgende ronde"}</td></tr>`).join("")
      || `<tr><td colspan="5" class="hint">Geen spelers.</td></tr>`;
    $("#recovery-invites").innerHTML = cp.invites.map(p => `<li><span class="t">${label(p.tile)}</span>
      <span><span class="swatch" style="background:#${esc(p.color)}"></span>${esc(p.name)}</span></li>`).join("") || `<li class="hint">Geen.</li>`;
    $("#recovery-plan").innerHTML = (cp.current?.type && (cp.state === "INTRO" || cp.state === "PLAYING")
      ? [`<li>${esc(title(cp.current.type))} <span class="hint">(opnieuw)</span></li>`] : []).concat(
      cp.upcoming.map(u => `<li>${esc(title(u.type))}${u.forced ? ` <span class="hint">(gekozen)</span>` : ""}</li>`)).join("");
  }
  const games = (live.nodes || []).filter(n => n.role === "master" || n.id === live.master?.node);
  const notice = info.db_notice;
  $("#recovery-sync").innerHTML = (games.map(n => `<div>${esc(n.id)}: ${!n.online ? `<span class="hint">offline</span>`
    : n.db_pending ? `<b class="bad">${n.db_pending} schrijfacties wachten op de server</b> (worden verstuurd zodra hij bereikbaar is)`
    : `<span class="good">✓ alles op de server</span>`}</div>`).join("") || `<div class="hint">Geen spel verbonden.</div>`)
    + `<div class="hint">${notice ? `Laatste wijziging aan het spel gemeld: ${esc({ players: "spelers", questions: "vragen", ranking: "ranglijst" }[notice.what] || notice.what)}, ${ago(Math.round(notice.ago))}.` : "Nog geen wijzigingen gemeld."}
      Wijzigingen (vragen, spelers, ranglijst) gaan meteen naar het spel.</div>`;
}
$("#recovery").onclick = e => {
  if (e.target.id === "recovery-clear" && confirm("De bewaarde spelstatus vergeten? De volgende start van het spel begint leeg."))
    api("DELETE", "/api/checkpoint");
};

// ---------------------------------------------------------------- tiles: places and physical tiles
let tileRows = [];
async function loadTiles() {
  tileRows = (await api("GET", "/api/tiles")).tiles;
  renderTileTable();
  renderLayout();
}

// the circle in the venue, like a clock seen from above: the entrance at 6, T01 at t01_clock
// ---------------------------------------------------------------- installation (partial setups)
let installDraft = null;                    // the checkboxes being edited (null: follow the server)

function parseRanges(s) {
  return s.split(",").flatMap(p => { const [a, b] = p.split("-").map(Number); return Array.from({ length: (b || a) - a + 1 }, (_, i) => a + i); });
}

function renderInstallation() {
  const on = new Set(installDraft || live.installed || Array.from({ length: PLACES }, (_, i) => i + 1));
  const setup = live.mode === "setup";
  $("#install-places").innerHTML = Array.from({ length: PLACES }, (_, i) => i + 1).map(t =>
    `<label class="install-place ${t > FLOOR_TILES ? "mobile" : ""}"><input type="checkbox" data-place="${t}" ${on.has(t) ? "checked" : ""}
      ${setup ? "" : "disabled"}> ${label(t)}</label>`).join("");
  document.querySelectorAll("#install-presets button, #install-save").forEach(b => b.disabled = !setup);
  $("#install-msg").textContent = setup ? (installDraft ? "niet opgeslagen" : `${on.size} plaatsen`) : "alleen in SETUP";
}
$("#install-presets").onclick = e => {
  const b = e.target.closest("button[data-preset]");
  if (b) { installDraft = parseRanges(b.dataset.preset); renderInstallation(); }
};
$("#install-places").onchange = () => {
  installDraft = [...document.querySelectorAll("#install-places input:checked")].map(i => Number(i.dataset.place));
  renderInstallation();
};
$("#install-save").onclick = async () => {
  if (!installDraft) return;
  await api("PUT", "/api/installation", { installed: installDraft });
  installDraft = null;
  renderInstallation();
};

function renderLayout() {
  renderInstallation();
  const installedSet = new Set(live.installed || []);
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
    const inst = !live.installed || installedSet.has(t);
    svg += `<g opacity="${inst ? 1 : 0.2}"><line x2="${x}" y2="${y}" stroke="var(--line)"/><circle cx="${x}" cy="${y}" r="13" fill="${t === 1 ? "var(--amber)" : "var(--panel)"}" stroke="var(--orange)" ${inst ? "" : 'stroke-dasharray="3 3"'}/>
      <text x="${x}" y="${y + 3.5}" text-anchor="middle" font-size="9" fill="${t === 1 ? "var(--bg)" : "var(--cream)"}">${label(t)}</text></g>`;
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

// ---------------------------------------------------------------- Prestaties: every component's performance
let perfTimer = null;
function startPerf() {
  if (perfTimer) return;
  perfTimer = setInterval(pollPerf, 2000);
  pollPerf();
}
async function pollPerf() {
  if (!$("#tab-perf").classList.contains("active")) { clearInterval(perfTimer); perfTimer = null; return; }
  try { renderPerf(await (await fetch("/api/metrics")).json()); } catch (e) { /* the next poll */ }
}
const num = (v, d = 0) => v == null || Number.isNaN(Number(v)) ? "–" : Number(v).toFixed(d);
// a value coloured by its thresholds: higher is worse (hi) or lower is worse (lo)
function lvl(v, warn, bad, lowerIsWorse = false) {
  if (v == null) return "";
  return lowerIsWorse ? (v < bad ? "bad" : v < warn ? "warn" : "good") : (v > bad ? "bad" : v > warn ? "warn" : "good");
}
const span = (cls, text) => `<span class="${cls}">${text}</span>`;
function dur(s) {
  if (s == null) return "–";
  s = Math.round(s);
  return s < 120 ? `${s} s` : s < 7200 ? `${Math.round(s / 60)} min` : s < 172800 ? `${(s / 3600).toFixed(1)} u` : `${Math.round(s / 86400)} d`;
}
function spark(values, max, target) {
  if (!values.length) return "";
  const w = 120, h = 22, top = Math.max(max, ...values, 1), n = Math.max(values.length - 1, 1);
  const pts = values.map((v, i) => `${(i / n * w).toFixed(1)},${(h - v / top * (h - 2) - 1).toFixed(1)}`).join(" ");
  const ty = target ? (h - target / top * (h - 2) - 1).toFixed(1) : null;
  return `<svg class="spark" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${ty ? `<line x1="0" x2="${w}" y1="${ty}" y2="${ty}"/>` : ""}<polyline points="${pts}"/></svg>`;
}
// fps: a Pi aims at 30 (a slow frame is over 1/30 s), the master at 60
const fpsLevel = n => lvl(n.fps, n.role === "display" ? 29 : 55, n.role === "display" ? 24 : 30, true);
function renderPerf(m) {
  const nodes = m.nodes || [], c = m.control || {}, b = m.broker || {};
  const master = nodes.find(n => n.role === "master"), displays = nodes.filter(n => n.role === "display");
  const tilesOn = (m.tiles || []).filter(t => t.online);
  const weakest = Math.min(...tilesOn.map(t => t.rssi ?? 0));
  const card = (cls, k, v, sub) => `<div class="card ${cls}"><div class="k">${esc(k)}</div><div class="v">${v}</div><div class="s">${sub}</div></div>`;
  const nodeCard = n => card(n.online ? fpsLevel(n) : "off", `${n.role === "master" ? "Master" : "Display"} ${n.id}`,
    n.online ? `${num(n.fps)} fps` : "offline", n.online ? `CPU ${num(n.cpu)}% · ${n.temp_c != null ? num(n.temp_c, 0) + " °C" : num(n.rss_mb) + " MB"}` : `${dur(n.age)} geleden`);
  $("#perf-cards").innerHTML = [
    master ? nodeCard(master) : card("off", "Master", "–", "stuurt geen metingen"),
    ...displays.map(nodeCard),
    card(c.mqtt ? lvl(c.cpu, 50, 90) : "bad", "Controleserver", `${num(c.cpu)}% CPU`, `${num(c.http_s, 1)} verz./s · ${c.sse} live`),
    card(b.clients != null ? "good" : "off", "MQTT-broker", b.clients != null ? `${num(b.clients)} clients` : "–",
      b.clients != null ? `${num(b.msgs_in_min)} / ${num(b.msgs_out_min)} ber./min` : "geen $SYS-gegevens"),
    card(!m.tiles?.length ? "off" : tilesOn.length < m.tiles.length ? "warn" : "good", "Tegels", `${tilesOn.length} / ${(m.tiles || []).length}`,
      tilesOn.length && Number.isFinite(weakest) && weakest < 0 ? `zwakste signaal ${weakest} dBm` : "online"),
    card(m.gamemasters ? "good" : "off", "Gamemaster-apps", String(m.gamemasters), "ingelogd"),
    card(m.website?.mock ? "off" : m.website?.status === "up" ? "good" : "bad", "Website", esc(m.website?.status || "–"),
      m.website?.latency_ms != null ? `${num(m.website.latency_ms)} ms` : ""),
  ].join("");

  $("#perf-nodes tbody").innerHTML = nodes.map(n => {
    const hist = n.hist || [];
    const machine = [n.load != null ? `load ${num(n.load, 2)}/${n.cpus}` : "", n.sys_mem_used != null ? `${num(n.sys_mem_used)}% RAM` : "",
      n.temp_c != null ? span(lvl(n.temp_c, 70, 80), `${num(n.temp_c, 0)} °C`) : "", n.cpu_mhz ? `${n.cpu_mhz} MHz` : ""].filter(Boolean).join(" · ");
    return `<tr><td><span class="dot ${n.online ? "on" : ""}"></span> ${esc(n.id)} <span class="hint">${esc(n.role)}</span></td>
      <td>${span(fpsLevel(n), num(n.fps))}${spark(hist.map(h => h[1]), n.role === "display" ? 30 : 60, n.role === "display" ? 30 : 60)}</td>
      <td>${num(n.frame_ms, 1)} / ${span(lvl(n.worst_ms, 50, 100), num(n.worst_ms))} ms</td>
      <td>${span(n.slow_frames > 5 ? "bad" : n.slow_frames ? "warn" : "good", num(n.slow_frames))}</td>
      <td>${num(n.cpu)}%</td><td>${num(n.rss_mb)} MB</td><td>${num(n.vram_mb)} MB</td>
      <td>${num(n.draw_calls)}</td><td>${num((n.primitives || 0) / 1000)}k</td><td>${num(n.nodes)}${n.orphans ? span("warn", ` (+${n.orphans} los)`) : ""}</td>
      <td>${machine || "–"}</td><td>${n.mqtt ? `${num(n.mqtt.in_s, 1)}↓ ${num(n.mqtt.out_s, 1)}↑ /s` : "–"}</td>
      <td class="hint">${esc(n.renderer)} · ${esc(n.gpu)}</td><td>${dur(n.uptime)}</td></tr>`;
  }).join("") || `<tr><td colspan="14" class="hint">Nog geen metingen: start het spel met --mqtt (de processen sturen ze elke 2 s).</td></tr>`;

  // a display link: the master's side (ENet's own statistics) with the display's side
  const links = master?.replica?.displays || [];
  const ids = [...new Set([...links.map(l => l.node), ...displays.map(d => d.id)])];
  $("#perf-links tbody").innerHTML = ids.map(id => {
    const l = links.find(x => x.node === id) || {}, d = displays.find(x => x.id === id), r = d?.replica || {};
    const up = links.some(x => x.node === id) || r.online;
    const rtt = l.rtt_ms ?? r.rtt_ms, jit = l.rtt_var_ms ?? r.rtt_var_ms, loss = l.loss ?? r.loss;
    return `<tr><td><span class="dot ${up ? "on" : ""}"></span> ${esc(id)}</td><td>${esc(l.host || "–")}</td>
      <td>${esc((l.screens || d?.screens_shown || []).join(", "))}</td>
      <td>${rtt != null ? span(lvl(rtt, 20, 100), num(rtt) + " ms") : "–"}</td>
      <td>${jit != null ? span(lvl(jit, 15, 60), num(jit) + " ms") : "–"}</td>
      <td>${loss != null ? span(lvl(loss, 1, 5), num(loss, 1) + "%") : "–"}</td>
      <td>${r.events != null ? `${r.events} <span class="hint">· ${r.deltas} delta's · ${r.live} live</span>` : "–"}</td>
      <td>${r.snapshots ?? "–"}</td>
      <td>${d ? (d.own_tiles_mqtt ? span("good", "ja") : span("warn", "nee (via de master)")) : "–"}</td>
      <td>${dur(l.connected_s ?? r.connected_s)}</td><td>${r.connects ? Math.max(r.connects - 1, 0) + "×" : "–"}</td></tr>`;
  }).join("") || `<tr><td colspan="11" class="hint">Geen displays (de master rendert alle schermen zelf, of geen --serve-replicas).</td></tr>`;
  const rp = master?.replica;
  $("#perf-mirror").textContent = rp ? `Displays op UDP-poort ${rp.port}: ${rp.events} gebeurtenissen, ${rp.deltas} delta's, `
    + `${rp.snapshots} snapshots verstuurd. Rondreis, jitter en verlies: ENet's eigen metingen per display. `
    + `De displays spelen het spel zelf af uit de spelstatus van de master; valt de verbinding weg, dan spelen ze door en halen ze bij terugkomst een nieuwe snapshot.` : "";

  const row = (k, v) => `<tr><td>${esc(k)}</td><td>${v}</td></tr>`;
  $("#perf-control").innerHTML = [
    row("CPU / geheugen", `${num(c.cpu)}% · ${num(c.rss_mb)} MB · ${c.threads ?? "–"} threads`),
    row("HTTP", `${num(c.http_s, 1)} verzoeken/s · ${c.http_ms != null ? num(c.http_ms, 1) + " ms gem." : "–"} · ${c.http_errors} fouten (5xx)`),
    row("Live-verbindingen", `${c.sse} (webinterface en toegankelijke pagina's)`),
    row("MQTT", `${c.mqtt ? span("good", "verbonden") : span("bad", "niet verbonden")} · ${num(c.mqtt_in_s, 1)} ber./s · ${num(c.mqtt_in_kbps, 1)} kbit/s · ${c.mqtt_reconnects}× herverbonden`),
    row("Machine", [c.load != null ? `load ${num(c.load, 2)}/${c.cpus}` : "", c.sys_mem_used != null ? `${num(c.sys_mem_used)}% van ${num(c.sys_mem_mb / 1024, 1)} GB` : "",
      c.temp_c != null ? `${num(c.temp_c, 0)} °C` : ""].filter(Boolean).join(" · ") || "–"),
    row("Actief", dur(c.uptime)),
  ].join("");
  $("#perf-broker").innerHTML = b.clients == null ? row("", `<span class="hint">Geen $SYS-tellers ontvangen (Mosquitto stuurt ze elke 10 s; een andere broker misschien niet).</span>`) : [
    row("Versie / actief", `${esc(b.version)} · ${esc(b.uptime)}`),
    row("Clients", `${num(b.clients)} verbonden (max ${num(b.clients_max)})`),
    row("Berichten", `${num(b.msgs_in_min)} in / ${num(b.msgs_out_min)} uit per min (gem. 1 min)`),
    row("Data", `${num(b.bytes_in_min * 8 / 60 / 1000, 1)} in / ${num(b.bytes_out_min * 8 / 60 / 1000, 1)} uit kbit/s`),
    row("Abonnementen / bewaard", `${num(b.subscriptions)} / ${num(b.retained)}`),
    row("Weggegooid", b.dropped ? span("warn", num(b.dropped)) : "0"),
  ].join("");

  $("#perf-tiles tbody").innerHTML = (m.tiles || []).map(t => `<tr><td><span class="dot ${t.online ? "on" : ""}"></span> ${esc(t.device)}</td>
    <td>${esc(t.fw || "–")}</td><td>${esc(t.net || "–")} <span class="hint">${esc(t.ip || "")}</span></td>
    <td>${t.rssi != null ? span(lvl(t.rssi, -70, -80, true), `${t.rssi} dBm`) : t.link != null ? esc(String(t.link)) : "–"}</td>
    <td>${t.loop_hz != null ? span(lvl(t.loop_hz, 500, 100, true), `${t.loop_hz} Hz`) : "–"}</td>
    <td>${t.heap != null ? span(lvl(t.heap / 1024, 40, 20, true), `${num(t.heap / 1024)} KB`) : "–"}</td>
    <td>${t.mqtt_reconnects != null ? `${t.mqtt_reconnects}×` : "–"}</td><td>${dur(t.uptime)}</td><td>${dur(t.age)} geleden</td></tr>`).join("")
    || `<tr><td colspan="9" class="hint">Geen fysieke tegels gezien.</td></tr>`;
  const streams = Object.entries(m.streams || {}).filter(([, s]) => s.on);
  $("#perf-streams").innerHTML = streams.length ? streams.map(([tile, s]) => `${label(Number(tile))}: ${esc(s.encoder || "")}${s.error ? span("bad", " " + esc(s.error)) : ""}`).join(" · ")
    : `Geen (de master: ${master ? master.streams ?? 0 : "–"} actief).`;
}

// ---------------------------------------------------------------- Verbindingen: who is connected
let clientsTimer = null;
const KINDS = { tile: ["Tegel", "🟧"], game: ["Spel", "🎮"], display: ["Display", "🖥"], control: ["Controleserver", "⚙"],
  gamemaster: ["Gamemaster-app", "📱"], other: ["Ander", "•"] };
function startClients() {
  if (clientsTimer) return;
  clientsTimer = setInterval(pollClients, 2000);
  pollClients();
}
async function pollClients() {
  if (!$("#tab-clients").classList.contains("active")) { clearInterval(clientsTimer); clientsTimer = null; return; }
  try { renderClients(await (await fetch("/api/clients")).json()); } catch (e) { /* the next poll */ }
}
function renderClients(c) {
  const list = c.clients || [];
  const count = k => list.filter(x => x.kind === k).length;
  const card = (cls, k, v, sub) => `<div class="card ${cls}"><div class="k">${esc(k)}</div><div class="v">${v}</div><div class="s">${sub}</div></div>`;
  const tiles = count("tile"), mqtt = list.filter(x => x.via === "MQTT").length;
  $("#clients-cards").innerHTML = [
    card(mqtt ? "good" : "off", "MQTT-clients", String(mqtt), c.broker_count != null ? `de broker telt er ${c.broker_count}` : "geen $SYS-tellers"),
    card(tiles ? "good" : "off", "Tegels", String(tiles), "verbonden met de broker"),
    card(count("game") ? "good" : "bad", "Spel", String(count("game")), "Godot-processen"),
    card(count("display") ? "good" : "off", "Displays", String(new Set(list.filter(x => x.kind === "display").map(x => x.name)).size),
      "Pi's (multiplayer + eigen tegels)"),
    card(count("gamemaster") + (c.web?.gamemasters?.length || 0) ? "good" : "off", "Gamemaster-apps",
      String(count("gamemaster") + (c.web?.gamemasters?.length || 0)), `${count("gamemaster")} MQTT · ${(c.web?.gamemasters || []).length} web`),
    card("good", "Webpagina's", String(c.web?.live ?? 0), "live verbindingen (beheer, toegankelijk)"),
  ].join("");
  $("#clients-table tbody").innerHTML = list.map(x => `<tr><td>${KINDS[x.kind]?.[1] || ""} ${esc(KINDS[x.kind]?.[0] || x.kind)}</td>
    <td><b>${esc(x.name)}</b></td><td class="hint">${esc(x.id)}</td><td>${esc(x.ip || "–")}</td><td>${esc(x.via)}</td>
    <td>${esc(x.user || "–")}</td><td>${dur(x.for_s)}</td><td class="hint">${esc(x.detail || "")}</td></tr>`).join("")
    || `<tr><td colspan="8" class="hint">Nog niemand gezien (de broker meldt verbindingen vanaf de start van de controleserver: Mosquitto met log_dest topic).</td></tr>`;
  const missing = c.broker_count != null ? c.broker_count - mqtt : 0;
  $("#clients-note").textContent = missing > 0
    ? `De broker telt ${c.broker_count} MQTT-clients, hier staan er ${mqtt}: wie verbond vóór de controleserver startte (${dur(c.known_since_s)} geleden), verschijnt pas als die opnieuw verbindt.`
    : `Bijgehouden sinds ${dur(c.known_since_s)} (de start van de controleserver).`;
  $("#clients-events").innerHTML = (c.events || []).map(e => `<li><span class="hint">${dur(e.ago)} geleden</span> ${esc(e.id)}
    <span class="${e.event === "verbonden" ? "good" : "warn"}">${esc(e.event)}</span></li>`).join("") || `<li class="hint">Nog niets.</li>`;
}

// ---------------------------------------------------------------- MQTT traffic
// (the game's state every 0.5 s, the tiles' displays, the announcements: "status" - hidden by default)
const QUIET = [/\/state$/, /\/node\//, /\/device\/[^/]+\/hello$/, /\/settings\/schema$/, /\/texts\/defaults$/];
let mqttSeq = 0, mqttPaused = false, mqttTimer = null, mqttRows = [];
function startMqttLog() {
  if (mqttTimer) return;
  mqttTimer = setInterval(pollMqtt, 1000);
  pollMqtt();
}
async function pollMqtt() {
  if (!$("#tab-mqtt").classList.contains("active")) { clearInterval(mqttTimer); mqttTimer = null; return; }
  if (mqttPaused) return;
  const r = await fetch(`/api/mqtt/log?since=${mqttSeq}&filter=${encodeURIComponent($("#mqtt-filter").value)}`);
  const res = await r.json();
  mqttSeq = res.seq;
  const quiet = $("#mqtt-quiet").checked;
  mqttRows = mqttRows.concat(res.messages.filter(m => !quiet || !QUIET.some(q => q.test(m.topic)))).slice(-500);
  $("#mqtt-count").textContent = `${mqttRows.length} berichten`;
  const box = $("#mqtt-log");
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
  box.innerHTML = mqttRows.map(m => `<div class="m"><span class="t">${esc(m.time)}</span>
    <span class="topic ${/\/(event|cmd)$/.test(m.topic) ? "hot" : ""}">${esc(m.topic)}</span>${m.retained ? '<span class="r">R</span>' : ""}
    <span class="p">${esc(m.payload)}</span></div>`).join("");
  if (atBottom) box.scrollTop = box.scrollHeight;
}
$("#mqtt-pause").onclick = e => {
  mqttPaused = !mqttPaused;
  e.target.textContent = mqttPaused ? "▶ Verder" : "⏸ Pauze";
};
$("#mqtt-clear").onclick = () => { mqttRows = []; $("#mqtt-log").innerHTML = ""; };
$("#mqtt-filter").oninput = $("#mqtt-quiet").onchange = () => { mqttRows = []; mqttSeq = 0; };

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

// ---------------------------------------------------------------- sounds
const SOUND_NAMES = {             // the game's own events (any other folder is shown by its name)
  charge: "robot laadt op", attack: "schot van de robot", hit: "tegel geraakt", shield: "schild blokkeert",
  death: "speler geëxtermineerd", zap: "tegel geëlektrocuteerd", explosion: "tegel ontploft", life: "+1 leven",
  round_start: "ronde begint", scoreboard: "scorebord", join: "speler doet mee", random: "willekeurig tussendoor",
};
let soundsJson = "";

function renderSounds() {
  const events = live.sounds || {};
  const json = JSON.stringify(events);
  if (json !== soundsJson) {                   // (only redraw when the list changed: keeps the buttons steady)
    soundsJson = json;
    const names = Object.keys(events).sort((a, b) => (a in SOUND_NAMES) - (b in SOUND_NAMES) || a.localeCompare(b));
    $("#sounds").innerHTML = names.length ? names.map(e => `<div class="sound">
        <div class="sound-head"><button data-sound="${esc(e)}">▶ ${esc(e)}</button>
          <span class="hint">${esc(SOUND_NAMES[e] || "eigen geluid")}</span></div>
        <div class="sound-files">${events[e].map(f =>
          `<button class="small" data-sound="${esc(e)}" data-file="${esc(f)}">${esc(f)}</button>`).join("")}</div>
      </div>`).join("")
      : `<p class="bad">Nog geen geluiden: er is geen spel (master) verbonden met MQTT.</p>`;
  }
  const base = location.origin;
  $("#sound-api").innerHTML = `
    <p><b>HTTP</b> (bv. een showcontroller, Bitfocus Companion, QLab): <code>POST ${esc(base)}/api/sound/&lt;geluid&gt;</code>,
      zonder body of met <code>{"file": "gong2.ogg", "volume": 60}</code>.
      Stoppen: <code>POST ${esc(base)}/api/sounds/stop</code>. De lijst: <code>GET ${esc(base)}/api/sounds</code>.</p>
    <pre>curl -X POST ${esc(base)}/api/sound/attack
curl -X POST ${esc(base)}/api/sound/attack -H 'Content-Type: application/json' -d '{"file": "laser2.ogg", "volume": 60}'</pre>
    <p><b>MQTT</b>: publiceer op <code>cybercircle/cmd</code>: <code>{"sound": "attack"}</code>,
      <code>{"sound": "attack", "file": "laser2.ogg", "volume": 60}</code>, <code>{"sound_stop": true}</code>.
      De lijst staat (retained) op <code>cybercircle/sounds</code>.</p>`;
}

function soundVolume() {
  return $("#sound-own-volume").checked ? Number($("#sound-volume").value) : -1;
}
$("#sound-volume").oninput = $("#sound-own-volume").onchange = () => {
  $("#sound-volume-label").textContent = $("#sound-own-volume").checked
    ? `${$("#sound-volume").value} %` : "volume uit Instellingen › Geluid";
};
$("#sounds").onclick = async e => {
  const b = e.target.closest("button[data-sound]");
  if (!b) return;
  await api("POST", `/api/sound/${encodeURIComponent(b.dataset.sound)}`, { file: b.dataset.file || "", volume: soundVolume() });
  b.classList.add("played");
  setTimeout(() => b.classList.remove("played"), 400);
};
$("#sound-stop").onclick = () => api("POST", "/api/sounds/stop");
$("#sound-reload").onclick = () => api("POST", "/api/sounds/reload");

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
