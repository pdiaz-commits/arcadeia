// Arcade AI — dedicated play view.
// Opened via window.open("/play?game=...&agent=...&mode=ai&lang=..").
// For hosted (ALE) games it runs the real live WebSocket JPEG stream + the
// agent's decision trace. For non-hosted (MAME) games it shows a clean
// "not available on this hosted server" panel and NEVER opens a WebSocket —
// so there is no perpetual "Connecting to the emulator…" state.

const params = new URLSearchParams(location.search);
const GAME = params.get("game") || "breakout";
const AGENT = params.get("agent") || "heuristic";

const state = {
  lang: params.get("lang") || localStorage.getItem("arcadeia_lang") || "en",
  i18n: {},
  game: null,
  ws: null,
};
if (!["en", "es"].includes(state.lang)) state.lang = "en";

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function applyI18n() {
  const d = state.i18n;
  $$("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    if (typeof d[key] === "string") el.textContent = d[key];
  });
}

async function loadI18n() {
  const res = await fetch(`/api/i18n/${state.lang}`);
  state.i18n = await res.json();
  applyI18n();
}

async function loadGame() {
  const res = await fetch("/api/games");
  const data = await res.json();
  state.game = (data.games || []).find((g) => g.key === GAME) || null;
}

function goBack() {
  // This view is meant to be a popup; try to close it, else navigate home.
  window.close();
  setTimeout(() => {
    if (!window.closed) location.href = "/";
  }, 150);
}

// ---------- unavailable (MAME) ----------

function showUnavailable() {
  const d = state.i18n;
  const title = (state.game && state.game.title) || GAME;
  $("#play-title").textContent = `🕹️ ${title}`;
  $("#unavailable-title").textContent = d.mameNoticeTitle || "Not available";
  $("#unavailable-body").textContent = (d.mameNoticeBody || "").replace("{game}", GAME);
  $("#play-unavailable").style.display = "block";
  $("#play-stream").style.display = "none";
}

// ---------- live stream (ALE) ----------

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
  traceRows = traceRows.slice(0, 14);
  $("#trace-body").innerHTML = traceRows
    .map(
      (r, i) =>
        `<tr class="${i === 0 ? "trace-row-new" : ""}"><td>${r.step}</td><td>${r.phase}</td><td>${r.reason}</td><td><code>${r.action}</code></td></tr>`
    )
    .join("");
  $("#trace-empty").style.display = traceRows.length ? "none" : "block";
}

function startStream() {
  if (state.ws) stopStream();

  traceRows = [];
  $("#trace-body").innerHTML = "";
  $("#trace-empty").style.display = "block";
  $("#play-error").textContent = "";
  $("#play-placeholder").style.display = "flex";
  $("#play-placeholder").textContent = state.i18n.aiConnecting || "Connecting…";
  $("#play-canvas").style.display = "none";

  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(
    `${proto}://${location.host}/ws/play?game=${encodeURIComponent(GAME)}&agent=${encodeURIComponent(AGENT)}&fps=20`
  );
  state.ws = ws;

  const canvas = $("#play-canvas");
  const ctx = canvas.getContext("2d");
  const img = new Image();
  img.onload = () => ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

  ws.onopen = () => {
    $("#play-live-tag").style.visibility = "visible";
  };

  ws.onmessage = (evt) => {
    const msg = JSON.parse(evt.data);
    if (msg.type === "connected") {
      $("#play-placeholder").style.display = "none";
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
      $("#play-error").textContent = msg.message;
      stopStream();
    }
  };

  ws.onclose = () => {
    if (state.ws === ws) {
      state.ws = null;
      $("#play-live-tag").style.visibility = "hidden";
    }
  };
  ws.onerror = () => {
    $("#play-error").textContent = "WebSocket error.";
  };
}

function stopStream() {
  if (state.ws) {
    try {
      state.ws.close();
    } catch (e) {}
    state.ws = null;
  }
  $("#play-live-tag").style.visibility = "hidden";
  $("#play-placeholder").style.display = "flex";
  $("#play-placeholder").textContent = state.i18n.aiIdlePlaceholder || "Stopped";
  $("#play-canvas").style.display = "none";
}

function showStream() {
  $("#play-title").textContent = `🕹️ ${(state.game && state.game.title) || GAME}`;
  $("#play-agent").textContent = AGENT;
  $("#play-stream").style.display = "";
  $("#play-unavailable").style.display = "none";
  renderTraceHeader();
  startStream();
}

// ---------- init ----------

async function init() {
  document.documentElement.lang = state.lang;
  await loadI18n();
  await loadGame();

  $("#back-btn").addEventListener("click", goBack);
  $("#unavailable-back-btn").addEventListener("click", goBack);

  // A game is streamable here only if the catalog marks it hosted (ALE).
  // Unknown keys are treated as not hosted (safe default: no dead WebSocket).
  const hosted = !!(state.game && state.game.hosted);
  if (!hosted) {
    showUnavailable();
    return;
  }

  $("#stop-btn").addEventListener("click", stopStream);
  $("#restart-btn").addEventListener("click", startStream);
  showStream();
}

init();
