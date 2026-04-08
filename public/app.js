function $(id) {
  return document.getElementById(id);
}

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function teamLabel(t) {
  // internal team index is 0-based
  return `{${t + 1}}`;
}

function refSlotsFromPreset(preset, courts) {
  const c = Math.max(1, parseInt(courts, 10) || 1);
  if (preset === "1") return c;
  // One ref per adjacent pair (1&2), (3&4), …; last court alone if odd — ceil(courts/2) slots.
  if (preset === "2") return Math.max(1, Math.ceil(c / 2));
  if (preset === "all") return 1;
  return Math.max(1, Math.ceil(c / 2));
}

function selectedRefLabelText(presetSelect) {
  const opt = presetSelect.options[presetSelect.selectedIndex];
  return opt ? opt.text : "";
}

const selectedTeams = new Set();

function syncSelectedTeamsFromOverview() {
  const summary = $("summary");
  if (!summary) return;
  selectedTeams.clear();
  summary.querySelectorAll('input.teamPick[type="checkbox"]').forEach((cb) => {
    if (!cb.checked) return;
    const t = parseInt(cb.dataset.team, 10);
    if (Number.isFinite(t)) selectedTeams.add(t);
  });
}

function applyTeamHighlights() {
  const rounds = $("rounds");
  if (!rounds) return;
  rounds.querySelectorAll("[data-team]").forEach((el) => {
    const t = parseInt(el.dataset.team, 10);
    const on = Number.isFinite(t) && selectedTeams.has(t);
    el.classList.toggle("teamHighlighted", on);
  });
}

function renderSummary(schedule) {
  const summary = $("summary");
  const teams = schedule.teams;
  const includeRef = schedule.includeRef;
  const gameCounts = schedule.teamGameCounts || Array.from({ length: teams }, () => schedule.gamesPerTeam);
  const refCounts = schedule.teamRefCounts;
  const byeCounts = schedule.teamByeCounts;
  const consecutiveByTeam = schedule.maxConsecutiveGamesByTeam || [];
  const warnings = schedule.warnings || [];
  const rounds = schedule.rounds || [];

  const breakStreak = Array.from({ length: teams }, () => 0);
  const maxBreakStreakByTeam = Array.from({ length: teams }, () => 0);
  rounds.forEach((round) => {
    const breakSet = new Set();
    (round.refs || []).forEach((r) => breakSet.add(r.team));
    (round.byes || []).forEach((t) => breakSet.add(t));
    for (let t = 0; t < teams; t++) {
      if (breakSet.has(t)) {
        breakStreak[t] += 1;
        if (breakStreak[t] > maxBreakStreakByTeam[t]) maxBreakStreakByTeam[t] = breakStreak[t];
      } else {
        breakStreak[t] = 0;
      }
    }
  });
  const maxConsecutiveBreaks = Math.max(...maxBreakStreakByTeam, 0);

  const distributeHomeAway = !!schedule.distributeHomeAway;
  const homeCounts = schedule.teamHomeCounts;
  const showHomeCol =
    distributeHomeAway && Array.isArray(homeCounts) && homeCounts.length === teams;

  const rows = [];
  for (let t = 0; t < teams; t++) {
    const consec = consecutiveByTeam[t] != null ? consecutiveByTeam[t] : "";
    const homeCell = showHomeCol ? `<td>${homeCounts[t]}</td>` : "";
    const checked = selectedTeams.has(t) ? "checked" : "";
    const teamCell = `<td>
      <label class="teamPickLabel">
        <input class="teamPick" type="checkbox" data-team="${t}" ${checked} />
        <span>${t + 1}</span>
      </label>
    </td>`;
    rows.push(
      `<tr>${teamCell}<td>${gameCounts[t]}</td>${homeCell}<td>${refCounts[t]}</td><td>${byeCounts[t]}</td><td>${consec}</td><td>${maxBreakStreakByTeam[t]}</td></tr>`
    );
  }

  const minRef = Math.min(...refCounts);
  const maxRef = Math.max(...refCounts);
  const minBye = Math.min(...byeCounts);
  const maxBye = Math.max(...byeCounts);
  const largestConsecutive = schedule.maxConsecutiveGamesOverall || 0;
  const seed = schedule.seed;
  const seedLine = seed !== undefined && seed !== null
    ? `<div class="muted seedLine">Seed: <b>${escapeHtml(String(seed))}</b></div>`
    : "";

  summary.innerHTML = `
    <div class="muted">Rounds total: <b>${schedule.roundsTotal}</b></div>
    <div class="muted">Rounds reffed per team: ${minRef}–${maxRef} &nbsp;|&nbsp; Byes per team: ${minBye}–${maxBye}</div>
    <div class="muted">Most consecutive games (any team): <b>${largestConsecutive}</b></div>
    <div class="muted">Max consecutive breaks: <b>${maxConsecutiveBreaks}</b></div>
    <div style="margin-top:10px">
      <table class="reportTable">
        <thead>
          <tr><th>Team</th><th>Matches</th>${showHomeCol ? "<th>Home</th>" : ""}<th>Refs</th><th>Byes</th><th>Max consecutive games</th><th>Max consecutive breaks</th></tr>
        </thead>
        <tbody>
          ${rows.join("")}
        </tbody>
      </table>
    </div>
    ${seedLine}
    ${warnings.length ? `<div class="error" style="margin-top:12px">${escapeHtml(warnings.join("\n"))}</div>` : ""}
  `;

  // Wire team highlight toggles (event delegation).
  summary.onchange = (e) => {
    const t = e.target;
    if (!t || !t.classList || !t.classList.contains("teamPick")) return;
    syncSelectedTeamsFromOverview();
    applyTeamHighlights();
  };
}

function renderRounds(schedule) {
  const roundsDiv = $("rounds");
  const courts = schedule.courts;
  const rounds = schedule.rounds;
  const includeRoundTime = schedule.includeRoundTime;
  const includeRef = schedule.includeRef;
  const refSlotLabels = (schedule.refSlotLabels || []).slice().sort((a, b) => a.slotIndex - b.slotIndex);
  roundsDiv.innerHTML = "";

  // Mirror the CSV structure exactly as an HTML table.
  const headers = ["Round"];
  if (includeRoundTime) headers.push("Time");
  for (let ci = 0; ci < courts; ci++) {
    headers.push(`Court ${ci + 1}A`);
    headers.push(`Court ${ci + 1}B`);
  }

  if (includeRef) {
    refSlotLabels.forEach((slot) => headers.push(slot.label));
  }

  headers.push("Bye");

  const table = document.createElement("table");
  table.classList.add("scheduleTable");

  const thead = document.createElement("thead");
  const headRow = document.createElement("tr");
  headers.forEach((h) => {
    const th = document.createElement("th");
    th.textContent = h;
    headRow.appendChild(th);
  });
  const firstCourtHeaderCol = 1 + (includeRoundTime ? 1 : 0);
  for (let ci = 0; ci < courts; ci++) {
    const colClass = ci % 2 === 0 ? "courtColEven" : "courtColOdd";
    const aCol = firstCourtHeaderCol + (ci * 2);
    const bCol = aCol + 1;
    if (headRow.children[aCol]) headRow.children[aCol].classList.add(colClass);
    if (headRow.children[bCol]) headRow.children[bCol].classList.add(colClass);
  }
  if (includeRef) {
    const refStart = firstCourtHeaderCol + (courts * 2);
    for (let i = 0; i < refSlotLabels.length; i++) {
      if (headRow.children[refStart + i]) headRow.children[refStart + i].classList.add("refCol");
    }
  }
  if (headRow.lastElementChild) headRow.lastElementChild.classList.add("byeCol");
  thead.appendChild(headRow);

  const tbody = document.createElement("tbody");

  rounds.forEach((round, ri) => {
    const tr = document.createElement("tr");
    // Round number is 1-based, matching CSV.
    const tdRound = document.createElement("td");
    tdRound.textContent = String(ri + 1);
    tr.appendChild(tdRound);

    if (includeRoundTime) {
      const tdTime = document.createElement("td");
      tdTime.textContent = schedule.roundTimes[ri].start;
      tr.appendChild(tdTime);
    }

    // Courts
    for (let ci = 0; ci < courts; ci++) {
      const game = round.games[ci];
      const tdA = document.createElement("td");
      const tdB = document.createElement("td");
      const colClass = ci % 2 === 0 ? "courtColEven" : "courtColOdd";
      tdA.classList.add(colClass);
      tdB.classList.add(colClass);
      if (!game) {
        tdA.textContent = "";
        tdB.textContent = "";
      } else {
        tdA.textContent = teamLabel(game[0]);
        tdB.textContent = teamLabel(game[1]);
        tdA.dataset.team = String(game[0]);
        tdB.dataset.team = String(game[1]);
      }
      tr.appendChild(tdA);
      tr.appendChild(tdB);
    }

    // Refs (if enabled)
    if (includeRef) {
      const refBySlotIndex = {};
      (round.refs || []).forEach((r) => {
        refBySlotIndex[r.slotIndex] = r.team;
      });

      refSlotLabels.forEach((slot) => {
        const td = document.createElement("td");
        td.classList.add("refCol");
        const teamIdx = refBySlotIndex.hasOwnProperty(slot.slotIndex) ? refBySlotIndex[slot.slotIndex] : null;
        td.textContent = teamIdx === null ? "" : teamLabel(teamIdx);
        if (teamIdx !== null) td.dataset.team = String(teamIdx);
        tr.appendChild(td);
      });
    }

    // Bye (semicolon-separated list in CSV)
    const tdBye = document.createElement("td");
    tdBye.classList.add("byeCol");
    const byesSorted = (round.byes || []).slice().sort((a, b) => a - b);
    if (byesSorted.length) {
      tdBye.textContent = "";
      byesSorted.forEach((t, i) => {
        if (i > 0) tdBye.appendChild(document.createTextNode(";"));
        const s = document.createElement("span");
        s.classList.add("byeTeamTag");
        s.dataset.team = String(t);
        s.textContent = teamLabel(t);
        tdBye.appendChild(s);
      });
    } else {
      tdBye.textContent = "";
    }
    tr.appendChild(tdBye);

    tbody.appendChild(tr);
  });

  table.appendChild(thead);
  table.appendChild(tbody);
  roundsDiv.appendChild(table);
  applyTeamHighlights();
}

function downloadCsv(filename, csvText) {
  const blob = new Blob([csvText], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function setDownloadEnabled(enabled, onClick) {
  const btns = [$("downloadBtn"), $("downloadBtnTop")].filter(Boolean);
  btns.forEach((b) => {
    b.disabled = !enabled;
    b.textContent = "Download CSV";
    b.onclick = enabled ? onClick : null;
  });
}

function setClearEnabled(enabled) {
  const btn = $("resetBtn");
  if (!btn) return;
  btn.disabled = !enabled;
}

function setPreviewVisible(visible) {
  const reportCard = $("reportCard");
  const scheduleCard = $("scheduleCard");
  const container = document.querySelector(".container");
  if (container) container.classList.toggle("withPreview", visible);
  [reportCard, scheduleCard].forEach((el) => {
    if (!el) return;
    el.classList.toggle("hiddenCard", !visible);
  });
}

function hasExistingPreview() {
  const scheduleCard = $("scheduleCard");
  const rounds = $("rounds");
  return !!scheduleCard && !scheduleCard.classList.contains("hiddenCard") && !!rounds && rounds.childElementCount > 0;
}

function setRefreshingPreview(active) {
  const reportCard = $("reportCard");
  const scheduleCard = $("scheduleCard");
  [reportCard, scheduleCard].forEach((el) => {
    if (!el) return;
    el.classList.toggle("refreshingPreview", !!active);
  });
}

function animatePreviewEntry() {
  const container = document.querySelector(".container");
  if (!container) return;
  container.classList.remove("previewEnter");
  // Force reflow so repeated updates retrigger animations.
  void container.offsetWidth;
  container.classList.add("previewEnter");

  const rows = document.querySelectorAll("#summary tbody tr, #rounds tbody tr");
  rows.forEach((row, i) => {
    row.style.animationDelay = `${Math.min(i * 18, 320)}ms`;
  });

  setTimeout(() => {
    container.classList.remove("previewEnter");
    rows.forEach((row) => {
      row.style.animationDelay = "";
    });
  }, 900);
}

function setGenerateLoading(active) {
  const row = $("generateLoading");
  const form = $("settingsForm");
  if (row) row.hidden = !active;
  if (form) form.setAttribute("aria-busy", active ? "true" : "false");
}

function sumSegmentSizes(arr) {
  return arr.reduce((a, b) => a + b, 0);
}

function evenSplitCourts(total, n) {
  const base = Math.floor(total / n);
  const rem = total % n;
  const arr = [];
  for (let i = 0; i < n; i++) arr.push(base + (i < rem ? 1 : 0));
  return arr;
}

function clampMinTwo(v) {
  const n = parseInt(v, 10);
  if (!Number.isFinite(n)) return 2;
  return Math.max(2, n);
}

// Keep sum == total and each segment >= 1.
// Priority: when segment i changes, adjust previous segments first (i-1, i-2, ...).
function rebalanceSegmentsInPlace(sizes, total, changedIdx) {
  for (let i = 0; i < sizes.length; i++) sizes[i] = clampMinTwo(sizes[i]);

  let diff = sumSegmentSizes(sizes) - total;
  if (diff === 0) return;

  const leftOrder = [];
  for (let i = changedIdx - 1; i >= 0; i--) leftOrder.push(i);
  const rightOrder = [];
  for (let i = changedIdx + 1; i < sizes.length; i++) rightOrder.push(i);
  const fallback = [];
  for (let i = sizes.length - 1; i >= 0; i--) {
    if (i !== changedIdx && !leftOrder.includes(i) && !rightOrder.includes(i)) fallback.push(i);
  }
  const order = [...leftOrder, ...rightOrder, ...fallback];

  if (diff > 0) {
    // Need to remove courts from other segments.
    while (diff > 0) {
      let moved = false;
      for (const idx of order) {
        if (diff <= 0) break;
        if (sizes[idx] > 2) {
          sizes[idx] -= 1;
          diff -= 1;
          moved = true;
        }
      }
      if (!moved) break;
    }
  } else {
    // Need to add courts to other segments.
    diff = -diff;
    let p = 0;
    while (diff > 0 && order.length > 0) {
      const idx = order[p % order.length];
      sizes[idx] += 1;
      diff -= 1;
      p += 1;
    }
    while (diff > 0) {
      sizes[changedIdx] += 1;
      diff -= 1;
    }
  }
}

function getSegmentSizesFromHidden(total, n) {
  const hidden = $("courtSegmentSizes");
  if (!hidden) return evenSplitCourts(total, n);
  try {
    const parsed = JSON.parse(hidden.value || "[]");
    if (Array.isArray(parsed) && parsed.length === n) {
      const sizes = parsed.map((x) => clampMinTwo(x));
      rebalanceSegmentsInPlace(sizes, total, n - 1);
      return sizes;
    }
  } catch (_) {
    // fallthrough
  }
  return evenSplitCourts(total, n);
}

function setSegmentSizesToHidden(sizes) {
  const hidden = $("courtSegmentSizes");
  if (hidden) hidden.value = JSON.stringify(sizes);
}

function renderSegmentFields(total, n) {
  const fields = $("segmentSizesFields");
  if (!fields) return;
  const sizes = getSegmentSizesFromHidden(total, n);
  setSegmentSizesToHidden(sizes);

  let html = "";
  for (let i = 0; i < n; i++) {
    html += `<label class="stackedInput fullWidthInput segmentSizeRow">
      <span>Courts in segment ${i + 1}</span>
      <input type="number" class="segmentSizeInput" data-seg-index="${i}" min="2" step="1" value="${sizes[i]}" />
    </label>`;
  }
  fields.innerHTML = html;
}

function syncCourtSegmentBlock() {
  const form = $("settingsForm");
  const block = $("segmentCourtsBlock");
  const cb = form?.querySelector('input[name="segmentCourts"]');
  if (!block || !form) return;
  if (!cb?.checked) {
    block.hidden = true;
    block.style.display = "none";
    const fields = $("segmentSizesFields");
    const lastRow = $("segmentLastRow");
    if (fields) fields.innerHTML = "";
    if (lastRow) lastRow.textContent = "";
    const hidden = $("courtSegmentSizes");
    if (hidden) hidden.value = "[]";
    return;
  }
  block.hidden = false;
  block.style.display = "";

  const total = parseInt(form.querySelector('input[name="courts"]').value, 10) || 0;
  const segCountEl = $("segmentCount");
  let n = parseInt(segCountEl?.value, 10) || 2;
  const fields = $("segmentSizesFields");
  const lastRow = $("segmentLastRow");
  const maxSegments = Math.max(1, Math.floor(total / 3));

  if (total < 2) {
    if (fields) fields.innerHTML = "";
    if (lastRow) lastRow.textContent = "Set at least two courts to use segments.";
    return;
  }

  if (maxSegments < 2) {
    if (segCountEl) {
      segCountEl.min = "1";
      segCountEl.max = String(maxSegments);
      segCountEl.value = "1";
    }
    if (fields) fields.innerHTML = "";
    if (lastRow) {
      lastRow.textContent =
        "At least 6 courts are required for segmented courts (max segments = 1 per 3 courts).";
    }
    const hidden = $("courtSegmentSizes");
    if (hidden) hidden.value = "[]";
    return;
  }

  n = Math.max(2, Math.min(n, maxSegments));
  if (segCountEl) {
    segCountEl.min = "2";
    segCountEl.max = String(maxSegments);
    segCountEl.value = String(n);
  }

  const key = `${total}|${n}`;
  if (block.dataset.segKey !== key) {
    block.dataset.segKey = key;
    renderSegmentFields(total, n);
  }
}

function initSegmentCourtsListeners() {
  const form = $("settingsForm");
  const fields = $("segmentSizesFields");
  if (!form || !fields || fields.dataset.delegationBound) return;
  fields.dataset.delegationBound = "1";
  fields.addEventListener("input", (e) => {
    const t = e.target;
    if (!t.classList || !t.classList.contains("segmentSizeInput")) return;
    const total = parseInt(form.querySelector('input[name="courts"]').value, 10) || 0;
    const n = parseInt($("segmentCount")?.value, 10) || 2;
    const changedIdx = parseInt(t.dataset.segIndex, 10) || 0;
    const sizes = [];
    fields.querySelectorAll(".segmentSizeInput").forEach((el) => {
      sizes.push(clampMinTwo(el.value));
    });
    if (sizes.length !== n) return;
    rebalanceSegmentsInPlace(sizes, total, changedIdx);
    fields.querySelectorAll(".segmentSizeInput").forEach((el, i) => {
      el.value = String(sizes[i]);
    });
    setSegmentSizesToHidden(sizes);
    persistFormState(form);
    syncGenerateAndReworkButtons();
  });
}

function persistFormState(form) {
  if (!form) return;
  const data = {};
  const fields = [
    "teams",
    "courts",
    "gamesPerTeam",
    "includeRef",
    "refSlotsPreset",
    "includeRoundTime",
    "startTime",
    "roundLengthMinutes",
    "ensureEachTeamHasBye",
    "includeHalfwayIntermission",
    "distributeHomeAway",
    "segmentCourts",
    "segmentCount",
    "courtSegmentSizes",
  ];
  fields.forEach((name) => {
    const el = form.querySelector(`[name="${name}"]`);
    if (!el) return;
    if (el.type === "checkbox") data[name] = !!el.checked;
    else data[name] = el.value;
  });
  localStorage.setItem("rr_form_state_v1", JSON.stringify(data));
}

function restoreFormState(form) {
  if (!form) return;
  let raw = null;
  try {
    raw = localStorage.getItem("rr_form_state_v1");
  } catch (_) {
    raw = null;
  }
  if (!raw) return;
  let data = null;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    data = null;
  }
  if (!data || typeof data !== "object") return;

  Object.entries(data).forEach(([name, value]) => {
    const el = form.querySelector(`[name="${name}"]`);
    if (!el) return;
    if (el.type === "checkbox") el.checked = !!value;
    else el.value = String(value ?? "");
  });
}

let lastPreviewPayload = null;
let lastPreviewKey = null;

function csvFilenameFromSchedule(schedule) {
  const teams = schedule.teams;
  const courts = schedule.courts;
  const matches = schedule.gamesPerTeam;
  const peerRefLabel = schedule.includeRef ? "Peer Ref" : "No Peer Ref";
  return `${teams} Teams_${courts} Courts_${matches} Matches_${peerRefLabel}.csv`;
}

function getFormKeyFromSettingsForm() {
  const form = $("settingsForm");
  if (!form) return "";

  // Ensure derived hidden fields (refSlotsPerRound + refLabelMode) match the current visible inputs.
  syncRefSlotsHiddenFromForm();

  const includeRef = form.querySelector('input[name="includeRef"]').checked ? "on" : "off";
  return [
    form.querySelector('input[name="teams"]').value,
    form.querySelector('input[name="courts"]').value,
    form.querySelector('input[name="gamesPerTeam"]').value,
    includeRef,
    form.querySelector('select[name="refSlotsPreset"]').value,
    form.querySelector('input[name="refSlotsPerRound"]').value,
    form.querySelector('input[name="refLabelMode"]').value,
    form.querySelector('input[name="includeRoundTime"]').checked ? "on" : "off",
    form.querySelector('input[name="startTime"]').value,
    form.querySelector('input[name="roundLengthMinutes"]').value,
    form.querySelector('input[name="ensureEachTeamHasBye"]').checked ? "on" : "off",
    form.querySelector('input[name="includeHalfwayIntermission"]')?.checked ? "on" : "off",
    form.querySelector('input[name="distributeHomeAway"]')?.checked ? "on" : "off",
    form.querySelector('input[name="segmentCourts"]')?.checked ? "on" : "off",
    form.querySelector('input[name="segmentCount"]')?.value ?? "",
    form.querySelector('input[name="courtSegmentSizes"]')?.value ?? "",
  ].join("|");
}

function syncGenerateAndReworkButtons() {
  const genBtn = $("generateBtn");
  const reworkBtn = $("reworkBtn");
  const clearBtn = $("resetBtn");

  const hasPreview = !!lastPreviewPayload;

  if (reworkBtn) reworkBtn.disabled = !hasPreview;
  if (clearBtn) setClearEnabled(hasPreview);

  if (!genBtn) return;
  if (!hasPreview) {
    genBtn.disabled = false;
    genBtn.textContent = "Generate";
    return;
  }

  const currentKey = getFormKeyFromSettingsForm();
  if (currentKey === lastPreviewKey) {
    genBtn.disabled = true;
    genBtn.textContent = "Generate";
  } else {
    genBtn.disabled = false;
    genBtn.textContent = "Update";
  }
}

async function generateSchedule({ payload = null, storePreview = true } = {}) {
  $("error").textContent = "";
  setDownloadEnabled(false, null);
  const refreshOldPreview = hasExistingPreview();

  const form = $("settingsForm");
  let effectivePayload = payload;
  if (!effectivePayload) {
    const formData = new FormData(form);

    // Apply ref slots preset.
    const includeRef = formData.get("includeRef") === "on";
    const courts = parseInt(formData.get("courts"), 10);
    if (includeRef) {
      const preset = formData.get("refSlotsPreset");
      const refSlots = refSlotsFromPreset(preset, courts);
      form.querySelector('input[name="refSlotsPerRound"]').value = String(refSlots);
    } else {
      form.querySelector('input[name="refSlotsPerRound"]').value = "0";
    }

    const teamCount = parseInt(formData.get("teams"), 10);
    const gamesPerTeam = parseInt(formData.get("gamesPerTeam"), 10);
    if (!Number.isFinite(teamCount) || teamCount < 2) {
      $("error").textContent = "Please enter a team count (2 or more).";
      return;
    }
    if (!Number.isFinite(courts) || courts < 1) {
      $("error").textContent = "Please enter a court count (1 or more).";
      return;
    }
    if (!Number.isFinite(gamesPerTeam) || gamesPerTeam < 1) {
      $("error").textContent = "Please enter games per team (1 or more).";
      return;
    }
    if (teamCount % 2 === 1) {
      if (gamesPerTeam % 2 === 1) {
        $("error").textContent =
          "Games per team must be an even number when using an odd team count.";
        return;
      }
      if (gamesPerTeam < 2) {
        $("error").textContent =
          "Games per team must be at least 2 when using an odd team count.";
        return;
      }
    }

    const segmentCourtsOn = formData.get("segmentCourts") === "on";
    let courtSegmentSizesPayload = null;
    if (segmentCourtsOn) {
      const maxSegments = Math.max(1, Math.floor(courts / 3));
      if (maxSegments < 2) {
        $("error").textContent =
          "Segment courts requires at least 6 courts (maximum 1 segment per 3 courts).";
        return;
      }
      let sizes = [];
      try {
        sizes = JSON.parse($("courtSegmentSizes")?.value || "[]");
      } catch (_) {
        sizes = [];
      }
      const sum = Array.isArray(sizes) ? sizes.reduce((a, b) => a + b, 0) : 0;
      if (!Array.isArray(sizes) || sizes.length < 2) {
        $("error").textContent =
          "Segment courts: choose at least two segments and valid court counts per segment.";
        return;
      }
      if (sum !== courts) {
        $("error").textContent =
          "Segment courts: courts per segment must add up to the total number of courts.";
        return;
      }
      if (sizes.some((x) => !Number.isFinite(x) || x < 2)) {
        $("error").textContent = "Segment courts: each segment must have at least two courts.";
        return;
      }
      if (sizes.length > maxSegments) {
        $("error").textContent =
          `Segment courts: number of segments cannot exceed ${maxSegments} for ${courts} courts.`;
        return;
      }
      courtSegmentSizesPayload = sizes;
    }

    effectivePayload = {
      teams: teamCount,
      courts: courts,
      includeRef: includeRef,
      refSlotsPerRound: parseInt(form.querySelector('input[name="refSlotsPerRound"]').value, 10),
      refLabelMode: formData.get("refLabelMode"),
      gamesPerTeam: gamesPerTeam,
      includeRoundTime: formData.get("includeRoundTime") === "on",
      avoidConsecutivePlay: true,
      roundLengthMinutes: parseInt(formData.get("roundLengthMinutes"), 10),
      startTime: formData.get("startTime"),
      ensureEachTeamHasBye: formData.get("ensureEachTeamHasBye") === "on",
      includeHalfwayIntermission: formData.get("includeHalfwayIntermission") === "on",
      distributeHomeAway: formData.get("distributeHomeAway") === "on",
      segmentCourts: segmentCourtsOn,
      courtSegmentSizes: courtSegmentSizesPayload,
    };
  }

  const genBtn = $("generateBtn");
  const reworkBtn = $("reworkBtn");
  setGenerateLoading(true);
  setRefreshingPreview(refreshOldPreview);
  if (genBtn) genBtn.disabled = true;
  if (reworkBtn) reworkBtn.disabled = true;

  try {
    const res = await fetch("/generate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(effectivePayload),
    });

    let data;
    try {
      data = await res.json();
    } catch (_) {
      $("error").textContent = "Could not read the server response.";
      return;
    }

    if (!res.ok) {
      $("error").textContent = data.error || "Failed to generate schedule.";
      return;
    }

    renderSummary(data);
    renderRounds(data);
    setPreviewVisible(true);
    animatePreviewEntry();

    if (storePreview) {
      lastPreviewPayload = effectivePayload;
      lastPreviewKey = getFormKeyFromSettingsForm();
    }

    setDownloadEnabled(true, () => downloadCsv(csvFilenameFromSchedule(data), data.csv));
    setClearEnabled(true);
  } catch (err) {
    $("error").textContent = err.message || String(err);
  } finally {
    setGenerateLoading(false);
    setRefreshingPreview(false);
    syncGenerateAndReworkButtons();
  }
}

function syncRefFieldLabel() {
  const x = $("refFieldX");
  const sel = $("refSlotsPreset");
  const wrap = $("refFieldLabelWrap");
  if (!x || !sel) return;
  const txt = selectedRefLabelText(sel);
  x.textContent = txt;
  if (wrap) {
    const noun = txt === "1" ? "court" : "courts";
    wrap.innerHTML = `Teams ref <span id="refFieldX">${escapeHtml(txt)}</span> ${noun} per round`;
  }
}

function syncRefSlotsHiddenFromForm() {
  const form = $("settingsForm");
  if (!form) return;
  const courts = parseInt(form.querySelector('input[name="courts"]').value, 10) || 1;
  const includeRef = form.querySelector('input[name="includeRef"]').checked;
  const preset = form.querySelector('select[name="refSlotsPreset"]').value;
  const hidden = form.querySelector('input[name="refSlotsPerRound"]');
  const refLabelMode = form.querySelector('input[name="refLabelMode"]');
  if (includeRef) {
    hidden.value = String(refSlotsFromPreset(preset, courts));
    if (refLabelMode) {
      // "paired" enables (1&2),(3&4),… column labels when teams ref two courts per slot; "unpaired" uses per-court or generic Ref N labels.
      refLabelMode.value = preset === "2" ? "paired" : "unpaired";
    }
  } else {
    hidden.value = "0";
  }
  syncRefFieldLabel();
}

function wireUi() {
  const form = $("settingsForm");
  restoreFormState(form);
  const segBlock = $("segmentCourtsBlock");
  if (segBlock) delete segBlock.dataset.segKey;
  initSegmentCourtsListeners();
  syncCourtSegmentBlock();
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const genBtn = $("generateBtn");
    if (genBtn && genBtn.disabled) return;
    generateSchedule({ storePreview: true }).catch((err) => {
      $("error").textContent = err.message || String(err);
    });
  });

  const genBtn = $("generateBtn");
  if (genBtn) {
    genBtn.addEventListener("click", () => {
      if (genBtn.disabled) return;
      generateSchedule({ storePreview: true }).catch((err) => {
        $("error").textContent = err.message || String(err);
      });
    });
  }

  const reworkBtn = $("reworkBtn");
  if (reworkBtn) {
    reworkBtn.addEventListener("click", () => {
      if (reworkBtn.disabled || !lastPreviewPayload) return;
      generateSchedule({ payload: lastPreviewPayload, storePreview: false }).catch((err) => {
        $("error").textContent = err.message || String(err);
      });
    });
  }

  $("resetBtn").addEventListener("click", () => {
    $("error").textContent = "";
    $("summary").innerHTML = "";
    $("rounds").innerHTML = "";
    setDownloadEnabled(false, null);
    lastPreviewPayload = null;
    lastPreviewKey = null;
    selectedTeams.clear();
    setPreviewVisible(false);
    syncGenerateAndReworkButtons();
  });

  // If includeRef is off, hide ref slots input.
  const includeRefCheckbox = form.querySelector('input[name="includeRef"]');
  const refField = form.querySelector(".refField");
  const courtsInput = form.querySelector('input[name="courts"]');
  const refPreset = form.querySelector('select[name="refSlotsPreset"]');
  const segmentCourtsCb = form.querySelector('input[name="segmentCourts"]');
  const segmentCountEl = $("segmentCount");

  function sync() {
    refField.style.display = includeRefCheckbox.checked ? "block" : "none";
    syncRefSlotsHiddenFromForm();
    syncGenerateAndReworkButtons();
  }
  includeRefCheckbox.addEventListener("change", sync);
  function onCourtsChange() {
    syncRefSlotsHiddenFromForm();
    const sb = $("segmentCourtsBlock");
    if (sb) delete sb.dataset.segKey;
    syncCourtSegmentBlock();
  }
  courtsInput.addEventListener("input", onCourtsChange);
  courtsInput.addEventListener("change", onCourtsChange);
  refPreset.addEventListener("change", syncRefSlotsHiddenFromForm);
  if (segmentCourtsCb) {
    segmentCourtsCb.addEventListener("change", () => {
      const sb = $("segmentCourtsBlock");
      if (sb) delete sb.dataset.segKey;
      syncCourtSegmentBlock();
      persistFormState(form);
      syncGenerateAndReworkButtons();
    });
  }
  if (segmentCountEl) {
    segmentCountEl.addEventListener("change", () => {
      const sb = $("segmentCourtsBlock");
      if (sb) delete sb.dataset.segKey;
      syncCourtSegmentBlock();
      persistFormState(form);
      syncGenerateAndReworkButtons();
    });
  }
  form.addEventListener("input", () => {
    persistFormState(form);
    syncGenerateAndReworkButtons();
  });
  form.addEventListener("change", () => {
    persistFormState(form);
    syncGenerateAndReworkButtons();
  });

  const includeRoundTimeCb = $("includeRoundTime");
  const roundTimesBlock = $("roundTimesBlock");
  function syncRoundTimeRow() {
    if (!roundTimesBlock) return;
    const show = includeRoundTimeCb && includeRoundTimeCb.checked;
    roundTimesBlock.classList.toggle("expanded", !!show);
  }
  if (includeRoundTimeCb) {
    includeRoundTimeCb.addEventListener("change", syncRoundTimeRow);
  }
  syncRoundTimeRow();

  sync();
  setDownloadEnabled(false, null);
  setClearEnabled(false);
  setPreviewVisible(false);
  syncGenerateAndReworkButtons();
}

wireUi();

