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

  const rows = [];
  for (let t = 0; t < teams; t++) {
    const consec = consecutiveByTeam[t] != null ? consecutiveByTeam[t] : "";
    rows.push(
      `<tr><td>${t + 1}</td><td>${gameCounts[t]}</td><td>${refCounts[t]}</td><td>${byeCounts[t]}</td><td>${consec}</td><td>${maxBreakStreakByTeam[t]}</td></tr>`
    );
  }

  const minRef = Math.min(...refCounts);
  const maxRef = Math.max(...refCounts);
  const minBye = Math.min(...byeCounts);
  const maxBye = Math.max(...byeCounts);
  const largestConsecutive = schedule.maxConsecutiveGamesOverall || 0;

  summary.innerHTML = `
    <div class="muted">Rounds total: <b>${schedule.roundsTotal}</b></div>
    <div class="muted">Rounds reffed per team: ${minRef}–${maxRef} &nbsp;|&nbsp; Byes per team: ${minBye}–${maxBye}</div>
    <div class="muted">Most consecutive games (any team): <b>${largestConsecutive}</b></div>
    <div class="muted">Max consecutive breaks: <b>${maxConsecutiveBreaks}</b></div>
    <div style="margin-top:10px">
      <table class="reportTable">
        <thead>
          <tr><th>Team</th><th>Matches</th><th>Refs</th><th>Byes</th><th>Max consecutive games</th><th>Max consecutive breaks</th></tr>
        </thead>
        <tbody>
          ${rows.join("")}
        </tbody>
      </table>
    </div>
    ${warnings.length ? `<div class="error" style="margin-top:12px">${escapeHtml(warnings.join("\n"))}</div>` : ""}
  `;
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
        tr.appendChild(td);
      });
    }

    // Bye (semicolon-separated list in CSV)
    const byes = (round.byes || []).slice().sort((a, b) => a - b).map((t) => teamLabel(t));
    const tdBye = document.createElement("td");
    tdBye.classList.add("byeCol");
    tdBye.textContent = byes.length ? byes.join(";") : "";
    tr.appendChild(tdBye);

    tbody.appendChild(tr);
  });

  table.appendChild(thead);
  table.appendChild(tbody);
  roundsDiv.appendChild(table);
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

async function generateSchedule() {
  $("error").textContent = "";
  setDownloadEnabled(false, null);

  const form = $("settingsForm");
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

  const payload = {
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
  };

  const res = await fetch("/generate", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  const data = await res.json();
  if (!res.ok) {
    $("error").textContent = data.error || "Failed to generate schedule.";
    return;
  }

  renderSummary(data);
  renderRounds(data);
  setPreviewVisible(true);

  const genBtn = $("generateBtn");
  if (genBtn) genBtn.textContent = "Refresh";

  setClearEnabled(true);
  setDownloadEnabled(true, () => downloadCsv("schedule.csv", data.csv));
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
  form.addEventListener("submit", (e) => {
    e.preventDefault();
    generateSchedule().catch((err) => {
      $("error").textContent = err.message || String(err);
    });
  });

  $("resetBtn").addEventListener("click", () => {
    $("error").textContent = "";
    $("summary").innerHTML = "";
    $("rounds").innerHTML = "";
    setDownloadEnabled(false, null);
    setClearEnabled(false);
    const genBtn = $("generateBtn");
    if (genBtn) genBtn.textContent = "Generate";
    setPreviewVisible(false);
  });

  // If includeRef is off, hide ref slots input.
  const includeRefCheckbox = form.querySelector('input[name="includeRef"]');
  const refField = form.querySelector(".refField");
  const courtsInput = form.querySelector('input[name="courts"]');
  const refPreset = form.querySelector('select[name="refSlotsPreset"]');

  function sync() {
    refField.style.display = includeRefCheckbox.checked ? "block" : "none";
    syncRefSlotsHiddenFromForm();
  }
  includeRefCheckbox.addEventListener("change", sync);
  courtsInput.addEventListener("input", syncRefSlotsHiddenFromForm);
  courtsInput.addEventListener("change", syncRefSlotsHiddenFromForm);
  refPreset.addEventListener("change", syncRefSlotsHiddenFromForm);
  form.addEventListener("input", () => persistFormState(form));
  form.addEventListener("change", () => persistFormState(form));

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
}

wireUi();

