// Arcade AI — front-end logic (vanilla JS, no build step).
// Talks to the real FastAPI backend in web/app.py: /api/games, /api/i18n,
// /ws/play (live ALE agent stream), /api/teach/sessions, /api/admin/*.

const state = {
  lang: localStorage.getItem("arcadeia_lang") || (navigator.language || "en").slice(0, 2),
  i18n: {},
  games: [],
  ws: null,
  hostedGames: [],
};

if (!["en", "es"].includes(state.lang)) state.lang = "en";

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function applyI18n() {
  const d = state.i18n;
  document.title = `${d.appTitle || "Arcade AI"} — ${d.subtitle || ""}`;
  $$("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    const val = d[key];
    if (typeof val === "string") el.textContent = val;
  });
  $$("[data-i18n-placeholder]").forEach((el) => {
    const key = el.getAttribute("data-i18n-placeholder");
    if (typeof d[key] === "string") el.placeholder = d[key];
  });

  if (d.tabs) {
    $$("#tabs button").forEach((btn) => {
      const tab = btn.getAttribute("data-tab");
      if (d.tabs[tab]) btn.textContent = d.tabs[tab];
    });
  }

  renderGamesTable();
  renderHowSteps();
  renderTraceHeader();
  renderTeachHeader();
  updateMameNotice();
}

async function loadI18n(lang) {
  const res = await fetch(`/api/i18n/${lang}`);
  state.i18n = await res.json();
  state.lang = lang;
  localStorage.setItem("arcadeia_lang", lang);
  renderLangSwitch();
  applyI18n();
}

function renderLangSwitch() {
  const el = $("#lang-switch");
  const langs = [
    { id: "en", flag: "🇬🇧" },
    { id: "es", flag: "🇪🇸" },
  ];
  el.innerHTML = "";
  for (const l of langs) {
    const btn = document.createElement("button");
    btn.textContent = `${l.flag} ${l.id.toUpperCase()}`;
    if (l.id === state.lang) btn.classList.add("active");
    btn.onclick = () => loadI18n(l.id);
    el.appendChild(btn);
  }
}

function setupTabs() {
  $$("#tabs button").forEach((btn) => {
    btn.addEventListener("click", () => {
      $$("#tabs button").forEach((b) => b.classList.remove("active"));
      $$(".tabpanel").forEach((p) => p.classList.remove("active"));
      btn.classList.add("active");
      $(`#tab-${btn.getAttribute("data-tab")}`).classList.add("active");
    });
  });
}

// ---------- Play tab: game catalog ----------

async function loadGames() {
  const res = await fetch("/api/games");
  const data = await res.json();
  state.games = data.games;
  state.hostedGames = data.games.filter((g) => g.hosted).map((g) => g.key);
  renderGamesTable();
  populateAiGameSelect();
}

function renderGamesTable() {
  const d = state.i18n;
  if (!d.gamesHeaders) return;
  $("#games-header").innerHTML = d.gamesHeaders.map((h) => `<th>${h}</th>`).join("");
  const rows = state.games
    .map((g) => {
      const statusLabel = g.status === "ready" ? d.statusReady : d.statusRomMissing;
      const hostedBadge = g.hosted
        ? `<span class="badge hosted">${d.statusHostedAle}</span>`
        : `<span class="badge ${g.status}">${d.statusNotHostedMame}</span>`;
      return `<tr>
        <td>${g.title}</td>
        <td><span class="engine-pill">${g.engine}</span></td>
        <td>${g.year ?? ""}</td>
        <td>${g.agent}</td>
        <td><span class="badge ${g.status}">${statusLabel}</span> ${hostedBadge}</td>
      </tr>`;
    })
    .join("");
  $("#games-body").innerHTML = rows;
}

function populateAiGameSelect() {
  const sel = $("#ai-game-select");
  sel.innerHTML = "";
  for (const g of state.games) {
    const opt = document.createElement("option");
    opt.value = g.key;
    opt.textContent = `${g.title} (${g.engine})`;
    if (!g.hosted) opt.dataset.hosted = "false";
    sel.appendChild(opt);
  }
  updateMameNotice();
}

function updateMameNotice() {
  const sel = $("#ai-game-select");
  if (!sel || !sel.options.length) return;
  const opt = sel.options[sel.selectedIndex];
  const hosted = opt && opt.dataset.hosted !== "false";
  const notice = $("#mame-notice");
  const startBtn = $("#ai-start-btn");
  if (hosted) {
    notice.style.display = "none";
    startBtn.disabled = false;
  } else {
    notice.style.display = "block";
    const body = (state.i18n.mameNoticeBody || "").replace("{game}", sel.value);
    $("#mame-notice-body").textContent = body;
    startBtn.disabled = true;
  }
}

// ---------- AI plays tab: live stream ----------

let traceRows = [];

function renderTraceHeader() {
  const d = state.i18n;
  if (!d.traceHeaders) return;
  $("#trace-header").innerHTML = d.traceHeaders.map((h) => `<th>${h}</th>`).join("");
}

function pushTrace(step, decision) {
  const phase = decision.phase || "–";
  const reason = decision.reason || "–";
  const action = decision.action ?? "–";
  traceRows.unshift({ step, phase, reason, action });
  traceRows = traceRows.slice(0, 12);
  $("#trace-body").innerHTML = traceRows
    .map(
      (r, i) =>
        `<tr class="${i === 0 ? "trace-row-new" : ""}"><td>${r.step}</td><td>${r.phase}</td><td>${r.reason}</td><td><code>${r.action}</code></td></tr>`
    )
    .join("");
  $("#trace-empty").style.display = traceRows.length ? "none" : "block";
}

function renderHowSteps() {
  const steps = state.i18n.howSteps || [];
  $("#how-steps").innerHTML = steps.map((s) => `<li>${s}</li>`).join("");
}

function startAiPlay() {
  const game = $("#ai-game-select").value;
  const agent = $("#ai-agent-select").value;
  if (state.ws) stopAiPlay();

  traceRows = [];
  $("#trace-body").innerHTML = "";
  $("#ai-error").textContent = "";
  $("#crt-placeholder").style.display = "flex";
  $("#crt-placeholder").textContent = state.i18n.aiConnecting || "Connecting…";
  $("#game-canvas").style.display = "none";

  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws/play?game=${encodeURIComponent(game)}&agent=${encodeURIComponent(agent)}&fps=20`);
  state.ws = ws;

  const canvas = $("#game-canvas");
  const ctx = canvas.getContext("2d");
  const img = new Image();
  img.onload = () => ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

  ws.onopen = () => {
    $("#ai-start-btn").style.display = "none";
    $("#ai-stop-btn").style.display = "block";
    $("#ai-live-tag").style.visibility = "visible";
  };

  ws.onmessage = (evt) => {
    const msg = JSON.parse(evt.data);
    if (msg.type === "connected") {
      $("#crt-placeholder").style.display = "none";
      canvas.style.display = "block";
    } else if (msg.type === "frame") {
      if (msg.frame) img.src = `data:image/jpeg;base64,${msg.frame}`;
      $("#hud-episode").textContent = msg.episode;
      $("#hud-step").textContent = msg.step;
      $("#hud-reward").textContent = msg.reward.toFixed(1);
      if (msg.decision && Object.keys(msg.decision).length) pushTrace(msg.step, msg.decision);
    } else if (msg.type === "episode_end") {
      // keep streaming into the next episode
    } else if (msg.type === "error") {
      $("#ai-error").textContent = msg.message;
      stopAiPlay();
    }
  };

  ws.onclose = () => {
    if (state.ws === ws) stopAiPlay();
  };
  ws.onerror = () => {
    $("#ai-error").textContent = "WebSocket error.";
  };
}

function stopAiPlay() {
  if (state.ws) {
    try {
      state.ws.close();
    } catch (e) {}
    state.ws = null;
  }
  $("#ai-start-btn").style.display = "block";
  $("#ai-stop-btn").style.display = "none";
  $("#ai-live-tag").style.visibility = "hidden";
}

// ---------- Teach tab ----------

function renderTeachHeader() {
  const d = state.i18n;
  if (!d.teachSessionsHeaders) return;
  $("#teach-header").innerHTML = d.teachSessionsHeaders.map((h) => `<th>${h}</th>`).join("");
}

async function loadTeachSessions() {
  const res = await fetch("/api/teach/sessions");
  const data = await res.json();
  const rows = data.sessions || [];
  $("#teach-body").innerHTML = rows
    .map((s) => `<tr><td><code>${s.name}</code></td><td>${s.markers}</td><td>${s.goals}</td><td>${s.last_frame}</td></tr>`)
    .join("");
  $("#teach-empty").style.display = rows.length ? "none" : "block";
}

// ---------- Admin tab ----------

async function loadAdminStatus() {
  const res = await fetch("/api/status");
  const data = await res.json();
  $("#admin-disabled-notice").style.display = data.admin_enabled ? "none" : "block";
  $("#version-tag").textContent = `v${data.version}`;
  if (data.admin_enabled) refreshAdminFiles();
}

function adminToken() {
  return $("#admin-token").value.trim();
}

async function refreshAdminFiles() {
  const token = adminToken();
  if (!token) return;
  try {
    const res = await fetch("/api/admin/files", { headers: { "X-Admin-Token": token } });
    if (!res.ok) return;
    const data = await res.json();
    $("#admin-roms-list").innerHTML = data.roms.map((r) => `<div class="file-row">📦 <code>${r}</code></div>`).join("") || "—";
    $("#admin-lua-list").innerHTML = data.lua.map((r) => `<div class="file-row">📜 <code>${r}</code></div>`).join("") || "—";
  } catch (e) {}
}

async function uploadFile(inputSel, statusSel, endpoint) {
  const input = $(inputSel);
  const file = input.files[0];
  const statusEl = $(statusSel);
  if (!file) return;
  const token = adminToken();
  if (!token) {
    statusEl.textContent = "Enter an admin token first.";
    statusEl.className = "notice-error";
    return;
  }
  const form = new FormData();
  form.append("file", file);
  statusEl.textContent = "Uploading…";
  statusEl.className = "";
  try {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "X-Admin-Token": token },
      body: form,
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Upload failed");
    statusEl.textContent = `Saved: ${data.path}`;
    statusEl.className = "notice-ok";
    refreshAdminFiles();
  } catch (e) {
    statusEl.textContent = e.message;
    statusEl.className = "notice-error";
  }
}

// ---------- init ----------

async function init() {
  setupTabs();
  await loadI18n(state.lang);
  await loadGames();
  await loadTeachSessions();
  await loadAdminStatus();

  $("#ai-game-select").addEventListener("change", updateMameNotice);
  $("#ai-start-btn").addEventListener("click", startAiPlay);
  $("#ai-stop-btn").addEventListener("click", stopAiPlay);
  $("#rom-upload-btn").addEventListener("click", () => uploadFile("#rom-file", "#rom-upload-status", "/api/admin/upload-rom"));
  $("#lua-upload-btn").addEventListener("click", () => uploadFile("#lua-file", "#lua-upload-status", "/api/admin/upload-lua"));
}

init();
