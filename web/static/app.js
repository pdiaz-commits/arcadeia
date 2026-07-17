// Arcade AI — landing / intro logic (vanilla JS, no build step).
// The landing is a cabinet showcase: pick a game + agent and launch a
// dedicated play window (/play). The real live WebSocket stream lives in
// that dedicated window (see play.js), never here — so the intro never shows
// a "connecting to emulator" state that could contradict the MAME notice.

const state = {
  lang: localStorage.getItem("arcadeia_lang") || (navigator.language || "en").slice(0, 2),
  i18n: {},
  games: [],
};

const SUPPORTED_LANGS = ["en", "es", "no", "fr", "de"];
if (!SUPPORTED_LANGS.includes(state.lang)) state.lang = "en";

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
  if (state.games.length) populateHeroGameSelect();
  renderHowSteps();
  renderHowToSteps();
  updateHero();
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
    { id: "no", flag: "🇳🇴" },
    { id: "fr", flag: "🇫🇷" },
    { id: "de", flag: "🇩🇪" },
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
      const tab = btn.getAttribute("data-tab");
      $$("#tabs button").forEach((b) => b.classList.remove("active"));
      $$(".tabpanel").forEach((p) => p.classList.remove("active"));
      btn.classList.add("active");
      $(`#tab-${tab}`).classList.add("active");
      // The cabinet showcase is the intro for the interactive tabs only.
      $("#hero").style.display = tab === "play" || tab === "ai" ? "" : "none";
    });
  });
}

// ---------- games / catalog ----------

async function loadGames() {
  const res = await fetch("/api/games");
  const data = await res.json();
  state.games = data.games;
  renderGamesTable();
  populateHeroGameSelect();
}

function renderGamesTable() {
  const d = state.i18n;
  if (!d.gamesHeaders) return;
  $("#games-header").innerHTML = d.gamesHeaders.map((h) => `<th>${h}</th>`).join("");
  const rows = state.games
    .map((g) => {
      let statusClass;
      let statusLabel;
      let hostedBadge;
      if (g.play_mode === "ale_live") {
        statusClass = "ready";
        statusLabel = d.statusReady;
        hostedBadge = `<span class="badge hosted">${d.statusHostedAle}</span>`;
      } else if (g.play_mode === "mame_live") {
        statusClass = "ready-live";
        statusLabel = d.statusReadyLive || d.statusReadyEducational;
        hostedBadge = `<span class="badge hosted-mame-live">${d.statusHostedMameLive || d.statusHostedMame}</span>`;
      } else if (g.play_mode === "mame_educational") {
        statusClass = "ready-educational";
        statusLabel = d.statusReadyEducational || d.statusRomReadyLocal;
        hostedBadge = `<span class="badge hosted-mame">${d.statusHostedMame}</span>`;
      } else if (g.status === "needs_rom") {
        statusClass = "needs_rom";
        statusLabel = d.statusRomMissing;
        hostedBadge = `<span class="badge ${statusClass}">${d.statusNotHostedMame}</span>`;
      } else {
        statusClass = "needs_rom";
        statusLabel = d.statusNeedsAgent || d.statusRomMissing;
        hostedBadge = `<span class="badge ${statusClass}">${d.statusNotHostedMame}</span>`;
      }
      return `<tr>
        <td>${g.title}</td>
        <td><span class="engine-pill">${g.engine}</span></td>
        <td>${g.year ?? ""}</td>
        <td>${g.agent}</td>
        <td><span class="badge ${statusClass}">${statusLabel}</span> ${hostedBadge}</td>
      </tr>`;
    })
    .join("");
  $("#games-body").innerHTML = rows;
}

function gameByKey(key) {
  return state.games.find((g) => g.key === key) || null;
}

function populateHeroGameSelect() {
  const sel = $("#hero-game-select");
  const d = state.i18n;
  const prev = sel.value;
  sel.innerHTML = "";

  const aleHosted = state.games.filter((g) => g.play_mode === "ale_live");
  const mameLive = state.games.filter((g) => g.play_mode === "mame_live");
  const mameEducational = state.games.filter((g) => g.play_mode === "mame_educational");
  const missing = state.games.filter((g) => !g.hosted);

  const addOption = (parent, g, suffix) => {
    const opt = document.createElement("option");
    opt.value = g.key;
    opt.textContent = `${g.title} (${g.engine})${suffix}`;
    opt.dataset.hosted = g.hosted ? "true" : "false";
    opt.dataset.playMode = g.play_mode || "";
    opt.dataset.title = g.title;
    parent.appendChild(opt);
  };

  if (aleHosted.length) {
    const grp = document.createElement("optgroup");
    grp.label = `▶ ${d.statusHostedAle || "playable here"}`;
    for (const g of aleHosted) addOption(grp, g, "");
    sel.appendChild(grp);
  }
  if (mameLive.length) {
    const grp = document.createElement("optgroup");
    grp.label = `▶ ${d.statusHostedMameLive || "MAME cabinet (live)"}`;
    for (const g of mameLive) addOption(grp, g, "");
    sel.appendChild(grp);
  }
  if (mameEducational.length) {
    const grp = document.createElement("optgroup");
    grp.label = `▶ ${d.statusHostedMame || "MAME cabinet (educational)"}`;
    for (const g of mameEducational) addOption(grp, g, "");
    sel.appendChild(grp);
  }
  if (missing.length) {
    const suffix = ` — ${d.statusNotHostedMame || "ROM missing"}`;
    const grp = document.createElement("optgroup");
    grp.label = d.statusNotHostedMame || "ROM missing";
    for (const g of missing) addOption(grp, g, suffix);
    sel.appendChild(grp);
  }

  if (prev && state.games.some((g) => g.key === prev)) {
    sel.value = prev;
  } else if (aleHosted.length) {
    sel.value = aleHosted[0].key;
  } else if (mameLive.length) {
    sel.value = mameLive[0].key;
  } else if (mameEducational.length) {
    sel.value = mameEducational[0].key;
  }

  updateHero();
}

function selectedGame() {
  const sel = $("#hero-game-select");
  if (!sel || !sel.options.length) return null;
  return sel.options[sel.selectedIndex] || null;
}

// Reflects the currently selected game on the cabinet: marquee, preview,
// educational MAME notice or unavailable state, and whether launch is allowed.
function updateHero() {
  const opt = selectedGame();
  const d = state.i18n;
  const marquee = $("#marquee-title");
  const previewTitle = $("#preview-title");
  const previewHint = $("#preview-hint");
  const preview = $("#cabinet-preview");
  const notice = $("#mame-notice");
  const launchBtn = $("#hero-launch-btn");

  if (!opt) {
    if (marquee) marquee.textContent = d.appTitle || "Arcade AI";
    if (previewTitle) previewTitle.textContent = d.heroSelectGame || "";
    if (previewHint) previewHint.textContent = "";
    return;
  }

  const g = gameByKey(opt.value);
  const playMode = (g && g.play_mode) || opt.dataset.playMode || "";
  const title = opt.dataset.title || opt.value;
  if (marquee) marquee.textContent = title;

  if (playMode === "ale_live") {
    if (preview) preview.classList.remove("preview-unavailable", "preview-educational", "preview-live");
    if (previewTitle) previewTitle.textContent = d.cabinetPreviewReady || "";
    if (previewHint) previewHint.textContent = d.cabinetPreviewReadyHint || "";
    if (notice) notice.style.display = "none";
    if (launchBtn) launchBtn.disabled = false;
  } else if (playMode === "mame_live") {
    if (preview) {
      preview.classList.remove("preview-unavailable", "preview-educational");
      preview.classList.add("preview-live");
    }
    if (previewTitle) previewTitle.textContent = d.cabinetPreviewLive || "";
    if (previewHint) previewHint.textContent = d.cabinetPreviewLiveHint || "";
    if (notice) {
      notice.style.display = "block";
      $("#mame-notice-title").textContent = d.mameDemoTitle || "";
      $("#mame-notice-body").textContent = d.legalFooter || d.mameDemoBody || "";
    }
    if (launchBtn) launchBtn.disabled = false;
  } else if (playMode === "mame_educational") {
    if (preview) {
      preview.classList.remove("preview-unavailable");
      preview.classList.add("preview-educational");
    }
    if (previewTitle) previewTitle.textContent = d.cabinetPreviewEducational || "";
    if (previewHint) previewHint.textContent = d.cabinetPreviewEducationalHint || "";
    if (notice) {
      notice.style.display = "block";
      $("#mame-notice-title").textContent = d.mameDemoTitle || "";
      $("#mame-notice-body").textContent = d.mameDemoBody || "";
    }
    if (launchBtn) launchBtn.disabled = false;
  } else {
    if (preview) {
      preview.classList.remove("preview-educational");
      preview.classList.add("preview-unavailable");
    }
    if (previewTitle) previewTitle.textContent = d.cabinetPreviewUnavailable || "";
    if (previewHint) previewHint.textContent = d.cabinetPreviewUnavailableHint || "";
    if (notice) {
      notice.style.display = "block";
      $("#mame-notice-title").textContent = d.mameNoticeTitle || "";
      $("#mame-notice-body").textContent = (d.mameNoticeBody || "").replace("{game}", opt.value);
    }
    if (launchBtn) launchBtn.disabled = true;
  }
}

// Opens the dedicated play view. Hosted ALE → live stream; hosted MAME →
// educational demo (snaps + Lua). Missing ROM → button stays disabled.
function launchPlay() {
  const opt = selectedGame();
  if (!opt || opt.dataset.hosted === "false") {
    updateHero();
    return;
  }
  const g = gameByKey(opt.value);
  if (g && (g.play_mode === "mame_educational" || g.play_mode === "mame_live") && !localStorage.getItem("arcadeia_legal_accepted")) {
    showLegalModal(() => launchPlayAfterLegal(opt));
    return;
  }
  launchPlayAfterLegal(opt);
}

function launchPlayAfterLegal(opt) {
  const game = opt.value;
  const agent = $("#hero-agent-select").value;
  const mode = opt.dataset.playMode || "ai";
  const params = new URLSearchParams({ game, agent, mode, lang: state.lang });
  const w = window.open(`/play?${params.toString()}`, "arcadeia_play", "noopener,width=1000,height=900");
  if (!w) {
    const msg = (state.i18n && state.i18n.popupBlocked) || "Allow pop-ups for this site, then try again.";
    alert(msg);
  }
}

function showLegalModal(onAccept) {
  const d = state.i18n;
  let modal = $("#legal-modal");
  if (!modal) {
    modal = document.createElement("div");
    modal.id = "legal-modal";
    modal.className = "legal-modal";
    modal.innerHTML = `
      <div class="legal-modal-card card">
        <h2 id="legal-modal-title"></h2>
        <p id="legal-modal-body"></p>
        <div class="legal-modal-actions">
          <button class="secondary" id="legal-decline-btn"></button>
          <button class="primary" id="legal-accept-btn"></button>
        </div>
      </div>`;
    document.body.appendChild(modal);
  }
  const titleEl =
    $("#legal-modal-title") || modal.querySelector("[data-i18n='legalDisclaimerTitle']") || modal.querySelector("h2");
  const bodyEl =
    $("#legal-modal-body") || modal.querySelector("[data-i18n='legalDisclaimerBody']") || modal.querySelector("p");
  if (titleEl) titleEl.textContent = d.legalDisclaimerTitle || "Legal notice";
  if (bodyEl) bodyEl.textContent = d.legalDisclaimerBody || "";
  const acceptBtn = $("#legal-accept-btn");
  const declineBtn = $("#legal-decline-btn");
  if (acceptBtn) acceptBtn.textContent = d.legalAccept || "Accept";
  if (declineBtn) declineBtn.textContent = d.legalDecline || "Cancel";
  modal.style.display = "flex";
  if (acceptBtn) {
    acceptBtn.onclick = () => {
      localStorage.setItem("arcadeia_legal_accepted", "1");
      modal.style.display = "none";
      onAccept();
    };
  }
  if (declineBtn) {
    declineBtn.onclick = () => {
      modal.style.display = "none";
    };
  }
}

function renderHowSteps() {
  const steps = state.i18n.howSteps || [];
  $("#how-steps").innerHTML = steps.map((s) => `<li>${s}</li>`).join("");
}

function renderHowToSteps() {
  const steps = state.i18n.howToUseSteps || [];
  const el = $("#howto-steps");
  if (el) el.innerHTML = steps.map((s) => `<li>${s}</li>`).join("");
}

// ---------- Teach tab ----------

async function loadTeachSessions() {
  const res = await fetch("/api/teach/sessions");
  const data = await res.json();
  const rows = data.sessions || [];
  const d = state.i18n;
  if (d.teachSessionsHeaders) {
    $("#teach-header").innerHTML = d.teachSessionsHeaders.map((h) => `<th>${h}</th>`).join("");
  }
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

  $("#hero-game-select").addEventListener("change", updateHero);
  $("#hero-launch-btn").addEventListener("click", launchPlay);
  $("#rom-upload-btn").addEventListener("click", () => uploadFile("#rom-file", "#rom-upload-status", "/api/admin/upload-rom"));
  $("#lua-upload-btn").addEventListener("click", () => uploadFile("#lua-file", "#lua-upload-status", "/api/admin/upload-lua"));
}

init();
