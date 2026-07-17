// Arcade AI — dedicated play view.
// ALE → real live WebSocket stream. MAME (ROM on server) → educational demo
// (real emulator snaps + Lua agent source). Missing ROM → unavailable panel.

const params = new URLSearchParams(location.search);
const GAME = params.get("game") || "breakout";
const AGENT = params.get("agent") || "heuristic";

const state = {
  lang: params.get("lang") || localStorage.getItem("arcadeia_lang") || "en",
  i18n: {},
  game: null,
  ws: null,
  snapTimer: null,
  audioCtx: null,
  audioNextTime: 0,
  audioMuted: false,
  audioEnabled: false,
};
if (!["en", "es", "no", "fr", "de"].includes(state.lang)) state.lang = "en";

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
  stopMameDemo();
  stopAudio();
  window.close();
  setTimeout(() => {
    if (!window.closed) location.href = "/";
  }, 150);
}

function ensureLegalAccepted() {
  return new Promise((resolve) => {
    if (localStorage.getItem("arcadeia_legal_accepted")) {
      resolve(true);
      return;
    }
    const d = state.i18n;
    const modal = $("#legal-modal");
    if (!modal) {
      resolve(false);
      return;
    }
    modal.style.display = "flex";
    $("#legal-accept-btn").onclick = () => {
      localStorage.setItem("arcadeia_legal_accepted", "1");
      modal.style.display = "none";
      resolve(true);
    };
    $("#legal-decline-btn").onclick = () => {
      modal.style.display = "none";
      resolve(false);
    };
  });
}

// ---------- fullscreen & audio ----------

function toggleFullscreen(wrapEl, btnEl) {
  if (!wrapEl) return;
  const d = state.i18n;
  const doc = document;
  const active = doc.fullscreenElement || doc.webkitFullscreenElement;
  if (!active) {
    const req = wrapEl.requestFullscreen || wrapEl.webkitRequestFullscreen;
    if (req) {
      req.call(wrapEl).catch(() => {});
    }
  } else {
    const exit = doc.exitFullscreen || doc.webkitExitFullscreen;
    if (exit) exit.call(doc);
  }
}

function updateFullscreenBtn(btnEl) {
  if (!btnEl) return;
  const d = state.i18n;
  const active = document.fullscreenElement || document.webkitFullscreenElement;
  btnEl.textContent = active ? d.playExitFullscreen || "Exit fullscreen" : d.playFullscreen || "Fullscreen";
}

function setupFullscreen(wrapId, btnId) {
  const wrap = $(wrapId);
  const btn = $(btnId);
  if (!wrap || !btn) return;
  btn.addEventListener("click", () => toggleFullscreen(wrap, btn));
  document.addEventListener("fullscreenchange", () => updateFullscreenBtn(btn));
  document.addEventListener("webkitfullscreenchange", () => updateFullscreenBtn(btn));
}

async function ensureAudioContext(sampleRate) {
  if (!state.audioCtx) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    state.audioCtx = new Ctx({ sampleRate: sampleRate || 48000 });
    state.audioNextTime = state.audioCtx.currentTime;
  }
  if (state.audioCtx.state === "suspended") {
    try {
      await state.audioCtx.resume();
    } catch (e) {}
  }
  return state.audioCtx;
}

function stopAudio() {
  if (state.audioCtx) {
    try {
      state.audioCtx.close();
    } catch (e) {}
    state.audioCtx = null;
    state.audioNextTime = 0;
  }
}

function playPcmChunk(base64Pcm, sampleRate) {
  if (state.audioMuted || !base64Pcm) return;
  const ctx = state.audioCtx;
  if (!ctx) return;
  const binary = atob(base64Pcm);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const int16 = new Int16Array(bytes.buffer);
  if (!int16.length) return;
  const floats = new Float32Array(int16.length);
  for (let i = 0; i < int16.length; i++) floats[i] = int16[i] / 32768;
  const buffer = ctx.createBuffer(1, floats.length, sampleRate || ctx.sampleRate);
  buffer.copyToChannel(floats, 0);
  const src = ctx.createBufferSource();
  src.buffer = buffer;
  src.connect(ctx.destination);
  const startAt = Math.max(state.audioNextTime, ctx.currentTime + 0.02);
  src.start(startAt);
  state.audioNextTime = startAt + buffer.duration;
}

function setupMuteButton() {
  const btn = $("#mute-btn");
  if (!btn) return;
  btn.addEventListener("click", async () => {
    state.audioMuted = !state.audioMuted;
    const d = state.i18n;
    btn.textContent = state.audioMuted ? d.playUnmute || "🔇 Unmute" : d.playMute || "🔊 Sound";
    if (!state.audioMuted && state.audioEnabled) {
      await ensureAudioContext();
    }
  });
}

function showMuteButton(enabled) {
  state.audioEnabled = enabled;
  const btn = $("#mute-btn");
  if (!btn) return;
  if (enabled) {
    btn.style.display = "";
    btn.textContent = state.i18n.playMute || "🔊 Sound";
  } else {
    btn.style.display = "none";
  }
}

// ---------- unavailable (no ROM) ----------

function showUnavailable() {
  const d = state.i18n;
  const title = (state.game && state.game.title) || GAME;
  $("#play-title").textContent = `🕹️ ${title}`;
  $("#unavailable-title").textContent = d.mameNoticeTitle || "Not available";
  $("#unavailable-body").textContent = (d.mameNoticeBody || "").replace("{game}", GAME);
  $("#play-unavailable").style.display = "block";
  $("#play-stream").style.display = "none";
  $("#play-mame").style.display = "none";
}

// ---------- MAME educational demo (crossfade carousel) ----------

const SNAP_HOLD_MS = 580;

let snapUrls = [];
let snapIdx = 0;
let snapActiveLayer = 0;

function mameSnapLayers() {
  return [$("#mame-snap-a"), $("#mame-snap-b")];
}

function updateMameSnapFrameLabel(displayIdx) {
  const el = $("#mame-snap-frame");
  if (!el || !snapUrls.length) return;
  const n = ((displayIdx % snapUrls.length) + snapUrls.length) % snapUrls.length;
  el.textContent = `${n + 1} / ${snapUrls.length}`;
}

function preloadSnapUrls(urls) {
  return Promise.all(
    urls.map(
      (url) =>
        new Promise((resolve, reject) => {
          const im = new Image();
          im.onload = () => resolve(url);
          im.onerror = () => reject(new Error(url));
          im.src = url;
        })
    )
  );
}

function showMameCarousel() {
  $("#mame-placeholder").style.display = "none";
  const carousel = $("#mame-snap-carousel");
  carousel.style.display = "block";
  carousel.setAttribute("aria-hidden", "false");
}

function hideMameCarousel() {
  const carousel = $("#mame-snap-carousel");
  carousel.style.display = "none";
  carousel.setAttribute("aria-hidden", "true");
  mameSnapLayers().forEach((layer) => {
    layer.classList.remove("is-active", "is-leaving", "is-entering", "no-transition");
    layer.removeAttribute("src");
  });
}

function advanceMameSnap(animate) {
  if (!snapUrls.length) return;
  const idx = snapIdx % snapUrls.length;
  const layers = mameSnapLayers();
  const incoming = layers[1 - snapActiveLayer];
  const outgoing = layers[snapActiveLayer];

  incoming.src = snapUrls[idx];
  if (!animate) {
    incoming.classList.add("no-transition", "is-active");
    outgoing.classList.remove("is-active", "is-leaving");
    snapActiveLayer = 1 - snapActiveLayer;
    snapIdx += 1;
    updateMameSnapFrameLabel(idx);
    requestAnimationFrame(() => incoming.classList.remove("no-transition"));
    return;
  }

  incoming.classList.remove("is-leaving", "is-active");
  outgoing.classList.remove("is-active");
  outgoing.classList.add("is-leaving");
  void incoming.offsetWidth;
  incoming.classList.add("is-active");
  setTimeout(() => outgoing.classList.remove("is-leaving"), 500);

  snapActiveLayer = 1 - snapActiveLayer;
  snapIdx += 1;
  updateMameSnapFrameLabel(idx);
}

function updateMameSnapPauseBtn() {
  const btn = $("#mame-snap-pause-btn");
  if (!btn) return;
  const d = state.i18n || {};
  const paused = state.snapPaused;
  btn.textContent = paused ? d.mameSnapPlay || "▶ Play" : d.mameSnapPause || "⏸ Pause";
  btn.setAttribute("aria-pressed", paused ? "false" : "true");
}

function pauseMameDemo() {
  state.snapPaused = true;
  stopMameDemo();
  updateMameSnapPauseBtn();
}

function resumeMameDemo(initial) {
  if (!snapUrls.length) return;
  state.snapPaused = false;
  updateMameSnapPauseBtn();
  stopMameDemo();
  if (initial) advanceMameSnap(false);
  state.snapTimer = setInterval(() => advanceMameSnap(true), SNAP_HOLD_MS);
}

function toggleMameDemoPause() {
  if (state.snapPaused) resumeMameDemo();
  else pauseMameDemo();
}

function stopMameDemo() {
  if (state.snapTimer) {
    clearInterval(state.snapTimer);
    state.snapTimer = null;
  }
}

async function showMameDemo() {
  const d = state.i18n;
  const title = (state.game && state.game.title) || GAME;
  $("#play-title").textContent = `🕹️ ${title}`;
  $("#play-agent").textContent = AGENT;
  $("#play-unavailable").style.display = "none";
  $("#play-stream").style.display = "none";
  $("#play-mame").style.display = "";

  const snapRes = await fetch(`/api/mame/${encodeURIComponent(GAME)}/snaps`);
  const snapData = await snapRes.json();
  snapUrls = snapData.snaps || [];
  snapIdx = 0;
  snapActiveLayer = 0;

  const luaRes = await fetch(`/api/mame/${encodeURIComponent(GAME)}/lua`);
  const luaData = await luaRes.json();
  $("#mame-lua-source").textContent = luaData.source || "—";

  const placeholder = $("#mame-placeholder");

  if (!snapUrls.length) {
    hideMameCarousel();
    const issue = snapData.rom_issue || "";
    const desc = snapData.description || state.game?.description || "";
    placeholder.innerHTML = "";
    const noTitle = document.createElement("strong");
    noTitle.className = "mame-no-snaps-title";
    noTitle.textContent = d.mameNoSnapsTitle || "No emulator captures available";
    placeholder.appendChild(noTitle);
    if (issue) {
      const pIssue = document.createElement("p");
      pIssue.className = "mame-no-snaps-issue";
      pIssue.textContent = issue;
      placeholder.appendChild(pIssue);
    }
    const pBody = document.createElement("p");
    pBody.textContent = desc || d.mameNoSnapsBody || d.mameDemoBody || "";
    placeholder.appendChild(pBody);
    placeholder.classList.add("placeholder-unavailable");
    placeholder.style.display = "flex";
    $("#mame-snap-pause-btn").style.display = "none";
    return;
  }

  placeholder.classList.remove("placeholder-unavailable");
  $("#mame-snap-pause-btn").style.display = "";
  state.snapPaused = false;
  updateMameSnapPauseBtn();

  stopMameDemo();
  try {
    await preloadSnapUrls(snapUrls);
  } catch {
    /* show anyway; browser may still load */
  }
  showMameCarousel();
  resumeMameDemo(true);
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

function startMameMjpeg() {
  stopStream();
  stopAudio();
  traceRows = [];
  $("#trace-body").innerHTML = "";
  $("#trace-empty").style.display = "block";
  $("#play-error").textContent = "";
  $("#play-placeholder").style.display = "flex";
  $("#play-placeholder").textContent = state.i18n.aiConnecting || "Connecting…";
  $("#play-canvas").style.display = "none";

  const streamImg = $("#play-stream-img");
  streamImg.style.display = "none";
  const crt = streamImg.closest(".play-crt");
  if (crt) crt.style.aspectRatio = "336 / 240";

  let sawFrame = false;
  const noVideoTimer = setTimeout(() => {
    if (!sawFrame) {
      $("#play-error").textContent =
        (state.i18n && state.i18n.noVideoFrames) ||
        "Connected but no video yet. The server may still be starting MAME — wait or refresh.";
    }
  }, 25000);

  streamImg.onload = () => {
    sawFrame = true;
    clearTimeout(noVideoTimer);
    $("#play-placeholder").style.display = "none";
    streamImg.style.display = "block";
    $("#play-live-tag").style.visibility = "visible";
    $("#play-error").textContent = "";
  };
  streamImg.onerror = () => {
    clearTimeout(noVideoTimer);
    $("#play-error").textContent =
      (state.i18n && state.i18n.mameSessionBusy) ||
      "Could not start MAME video stream. Another session may be active.";
    streamImg.style.display = "none";
    $("#play-placeholder").style.display = "flex";
  };

  const url = `/api/mame/live.mjpg?game=${encodeURIComponent(GAME)}&agent=${encodeURIComponent(AGENT)}&fps=30`;
  streamImg.src = `${url}&_=${Date.now()}`;
  state.mameMjpeg = true;
}

function startStream() {
  if (state.ws) stopStream();

  stopAudio();
  traceRows = [];
  $("#trace-body").innerHTML = "";
  $("#trace-empty").style.display = "block";
  $("#play-error").textContent = "";
  $("#play-placeholder").style.display = "flex";
  $("#play-placeholder").textContent = state.i18n.aiConnecting || "Connecting…";
  $("#play-canvas").style.display = "none";

  const fps = state.game && state.game.play_mode === "mame_live" ? "20" : "20";
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(
    `${proto}://${location.host}/ws/play?game=${encodeURIComponent(GAME)}&agent=${encodeURIComponent(AGENT)}&fps=${fps}`
  );
  ws.binaryType = "arraybuffer";
  state.ws = ws;

  const canvas = $("#play-canvas");
  const ctx = canvas.getContext("2d");
  const streamImg = $("#play-stream-img");
  const img = new Image();
  let lastBlobUrl = null;
  let mameBinaryFrames = false;

  function showAleFrame(src) {
    sawFrame = true;
    clearTimeout(noVideoTimer);
    $("#play-error").textContent = "";
    $("#play-placeholder").style.display = "none";
    canvas.style.display = "none";
    streamImg.style.display = "block";
    streamImg.src = src;
  }

  function drawJpegBuffer(buffer) {
    if (mameBinaryFrames) {
      sawFrame = true;
      clearTimeout(noVideoTimer);
      $("#play-error").textContent = "";
      $("#play-placeholder").style.display = "none";
      canvas.style.display = "none";
      streamImg.style.display = "block";
      const blob = new Blob([buffer], { type: "image/jpeg" });
      const url = URL.createObjectURL(blob);
      streamImg.onload = () => {
        if (lastBlobUrl) URL.revokeObjectURL(lastBlobUrl);
        lastBlobUrl = url;
      };
      streamImg.src = url;
      return;
    }
    const blob = new Blob([buffer], { type: "image/jpeg" });
    const url = URL.createObjectURL(blob);
    img.onload = () => {
      showAleFrame(url);
      if (lastBlobUrl) URL.revokeObjectURL(lastBlobUrl);
      lastBlobUrl = url;
    };
    img.src = url;
  }

  ws.onopen = () => {
    $("#play-live-tag").style.visibility = "visible";
  };

  let sawFrame = false;
  const noVideoTimer = setTimeout(() => {
    if (!sawFrame && state.ws === ws) {
      $("#play-error").textContent =
        (state.i18n && state.i18n.noVideoFrames) ||
        "Connected but no video yet. The server may still be starting MAME — wait or refresh.";
    }
  }, 15000);

  ws.onmessage = (evt) => {
    if (mameBinaryFrames && (evt.data instanceof ArrayBuffer)) {
      drawJpegBuffer(evt.data);
      return;
    }
    if (mameBinaryFrames && evt.data instanceof Blob) {
      evt.data.arrayBuffer().then(drawJpegBuffer);
      return;
    }
    const msg = JSON.parse(evt.data);
    if (msg.type === "connected") {
      mameBinaryFrames = !!msg.binaryFrames;
      $("#play-placeholder").style.display = "none";
      if (msg.width && msg.height) {
        const crt = canvas.closest(".play-crt");
        if (crt) crt.style.aspectRatio = `${msg.width} / ${msg.height}`;
        if (mameBinaryFrames) {
          streamImg.width = msg.width;
          streamImg.height = msg.height;
        } else {
          canvas.width = msg.width;
          canvas.height = msg.height;
        }
      }
      if (mameBinaryFrames) {
        canvas.style.display = "none";
        streamImg.style.display = "block";
      } else {
        canvas.style.display = "none";
        streamImg.style.display = "block";
      }
      if (msg.audio) {
        showMuteButton(true);
        ensureAudioContext(msg.sampleRate || 48000);
      } else {
        showMuteButton(false);
      }
    } else if (msg.type === "audio") {
      if (msg.pcm && state.audioEnabled) {
        if (!state.audioCtx) ensureAudioContext(msg.rate || 48000);
        playPcmChunk(msg.pcm, msg.rate || 48000);
      }
    } else if (msg.type === "frame") {
      if (msg.frame && !mameBinaryFrames) {
        showAleFrame(`data:image/jpeg;base64,${msg.frame}`);
      }
      $("#hud-episode").textContent = msg.episode;
      $("#hud-step").textContent = msg.step;
      $("#hud-reward").textContent = msg.reward.toFixed(1);
      if (msg.decision && Object.keys(msg.decision).length) pushTrace(msg.step, msg.decision);
    } else if (msg.type === "session_timeout") {
      $("#play-error").textContent =
        (state.i18n && state.i18n.mameSessionTimeout) || msg.message;
      stopStream();
    } else if (msg.type === "error") {
      if (msg.code === "too_many_requests") {
        $("#play-error").textContent =
          (state.i18n && state.i18n.mameSessionBusy) || msg.message;
      } else {
        $("#play-error").textContent = msg.message;
      }
      stopStream();
    }
  };

  ws.onclose = () => {
    clearTimeout(noVideoTimer);
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
  if (state.mameMjpeg) {
    const streamImg = $("#play-stream-img");
    streamImg.onload = null;
    streamImg.onerror = null;
    streamImg.src = "";
    streamImg.style.display = "none";
    state.mameMjpeg = false;
  }
  stopAudio();
  showMuteButton(false);
  $("#play-live-tag").style.visibility = "hidden";
  $("#play-placeholder").style.display = "flex";
  $("#play-placeholder").textContent = state.i18n.aiIdlePlaceholder || "Stopped";
  $("#play-canvas").style.display = "none";
}

function showStream(isMameLive) {
  $("#play-title").textContent = `🕹️ ${(state.game && state.game.title) || GAME}`;
  $("#play-agent").textContent = AGENT;
  $("#play-stream").style.display = "";
  $("#play-mame").style.display = "none";
  $("#play-unavailable").style.display = "none";
  const liveLabel = isMameLive
    ? (state.i18n.mameLiveTag || "LIVE — MAME")
    : (state.i18n.aiLive || "LIVE");
  $("#play-live-tag").innerHTML = `<span class="live-dot"></span> <span>${liveLabel}</span>`;
  renderTraceHeader();
  if (isMameLive) {
    startMameMjpeg();
  } else {
    startStream();
  }
}

// ---------- init ----------

async function init() {
  document.documentElement.lang = state.lang;
  await loadI18n();
  await loadGame();

  $("#back-btn").addEventListener("click", goBack);
  $("#unavailable-back-btn").addEventListener("click", goBack);
  setupFullscreen("#play-screen-wrap", "#fullscreen-btn");
  setupFullscreen("#mame-screen-wrap", "#mame-fullscreen-btn");
  setupMuteButton();
  const mamePauseBtn = $("#mame-snap-pause-btn");
  if (mamePauseBtn) {
    mamePauseBtn.addEventListener("click", toggleMameDemoPause);
  }

  const playMode = state.game && state.game.play_mode;

  if (playMode === "mame_educational") {
    const ok = await ensureLegalAccepted();
    if (!ok) {
      goBack();
      return;
    }
    await showMameDemo();
    return;
  }

  if (playMode === "mame_live" || playMode === "ale_live") {
    if (playMode === "mame_live") {
      const ok = await ensureLegalAccepted();
      if (!ok) {
        goBack();
        return;
      }
    }
    $("#stop-btn").addEventListener("click", stopStream);
    $("#restart-btn").addEventListener("click", () => {
      if (playMode === "mame_live") startMameMjpeg();
      else startStream();
    });
    showStream(playMode === "mame_live");
    return;
  }

  if (playMode !== "ale_live") {
    showUnavailable();
    return;
  }

  $("#stop-btn").addEventListener("click", stopStream);
  $("#restart-btn").addEventListener("click", startStream);
  showStream(false);
}

init();
