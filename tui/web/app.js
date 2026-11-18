"use strict";
// Triage inbox. No decision logic here: every verdict is made by the server.
// All dynamic text goes through textContent.
const TOKEN = document.querySelector('meta[name="meute-token"]').content;
const $ = (id) => document.getElementById(id);
// Beacons: tell the server the page rendered, or why it did not (tests/test_browser_smoke.py).
const beacon = (url) => { fetch(url, { keepalive: true }).catch(() => {}); };
window.onerror = (msg, src, line) => {
  beacon("/api/client-error?msg=" + encodeURIComponent(msg + " @" + src + ":" + line));
};
const state = { data: null, rows: [], sel: -1, tab: "findings", busy: false };

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null) e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}

function notice(msg, ok) {
  const n = $("notice");
  n.textContent = msg;
  n.className = ok ? "ok" : "err";
}

async function getJSON(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(url + " -> HTTP " + r.status);
  return r.json();
}

async function postAct(payload) {
  const r = await fetch("/api/act", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Meute-Token": TOKEN },
    body: JSON.stringify(payload),
  });
  let body = null;
  try { body = await r.json(); } catch (e) { body = null; }
  if (!r.ok) throw new Error((body && body.message) || "HTTP " + r.status);
  return body;
}

// ---- tabs -----------------------------------------------------------------
function showTab(name) {
  state.tab = name;
  document.querySelectorAll("#tabs button").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === name);
  });
  document.querySelectorAll("section.tab").forEach((s) => { s.hidden = s.id !== name; });
  document.dispatchEvent(new CustomEvent("meute:tab", { detail: name }));
}
window.meuteShowTab = showTab;

// ---- findings -------------------------------------------------------------
const COLS = ["repo", "severity", "title", "location", "lens", "date", "state"];

// gone, superseded and claimed rows are hidden as decided ones are (D7);
// `hidden` comes from lib/finding_status.py, the CLI's own rule.
function isDecided(f) { return f.state !== "new" || Boolean(f.inherited) || Boolean(f.hidden); }

function cell(f, c) {
  if (c !== "state") return f[c];
  const label = f.claimed ? "claimed" : f.state;
  return f.verdict && f.verdict !== "current" && f.verdict !== "unknown" ? label + " / " + f.verdict : label;
}

function visibleRows() {
  const q = $("filter").value.trim().toLowerCase();
  const all = $("show-decided").checked;
  return (state.data ? state.data.findings : []).filter((f) => {
    if (!all && isDecided(f)) return false;
    if (!q) return true;
    return COLS.some((c) => String(f[c] === undefined ? "" : f[c]).toLowerCase().includes(q));
  });
}

function renderFindings() {
  const keep = state.sel >= 0 && state.rows[state.sel]
    ? state.rows[state.sel].report + "#" + state.rows[state.sel].n : null;
  state.rows = visibleRows();
  state.sel = keep ? state.rows.findIndex((f) => f.report + "#" + f.n === keep) : -1;
  const tb = document.querySelector("#findings-table tbody");
  tb.replaceChildren();
  state.rows.forEach((f, i) => {
    const tr = el("tr", null, "finding" + (isDecided(f) ? " decided" : ""));
    COLS.forEach((c) => {
      const td = el("td", cell(f, c));
      if (c === "severity") td.className = "sev-" + String(f.severity).toLowerCase();
      tr.appendChild(td);
    });
    tr.addEventListener("click", () => select(i));
    if (i === state.sel) tr.classList.add("selected");
    tb.appendChild(tr);
  });
  $("count").textContent = state.rows.length + " shown";
  if (state.sel < 0) $("panel").hidden = true;
}

function markSelected() {
  document.querySelectorAll("#findings-table tbody tr").forEach((tr, i) => {
    tr.classList.toggle("selected", i === state.sel);
    if (i === state.sel) tr.scrollIntoView({ block: "nearest" });
  });
}

async function select(i) {
  if (i < 0 || i >= state.rows.length) return;
  state.sel = i;
  markSelected();
  const f = state.rows[i];
  $("panel").hidden = false;
  $("panel-title").textContent = f.report + " #" + f.n + "  " + f.title;
  $("panel-body").textContent = "loading...";
  $("resolve-message").value = "";
  $("dismiss-message").value = "";
  $("dismiss-reason").selectedIndex = 0;
  try {
    const r = await fetch("/api/finding?id=" + encodeURIComponent(f.report) + "&n=" + encodeURIComponent(f.n));
    if (!r.ok) throw new Error("HTTP " + r.status);
    const text = await r.text();
    if (state.rows[state.sel] === f) $("panel-body").textContent = text;
  } catch (e) {
    $("panel-body").textContent = "could not load evidence: " + e.message;
  }
}

function move(d) {
  if (!state.rows.length) return;
  const next = Math.min(state.rows.length - 1, Math.max(0, (state.sel < 0 ? (d > 0 ? -1 : 1) : state.sel) + d));
  select(next);
}

function fillReasons() {
  const sel = $("dismiss-reason");
  sel.replaceChildren(el("option", "-- reason --"));
  sel.firstChild.value = "";
  (state.data.dismiss_reasons || []).forEach((r) => {
    const o = el("option", r);
    o.value = r;
    sel.appendChild(o);
  });
}

async function act(verb) {
  if (state.busy) return;
  const f = state.rows[state.sel];
  if (!f) { notice("select a finding first", false); return; }
  const payload = { verb: verb, id: f.report, n: f.n };
  if (verb === "promote") {
    if (!window.confirm("Promote " + f.report + " #" + f.n + "?")) return;
  } else if (verb === "dismiss") {
    const reason = $("dismiss-reason").value;
    if (!reason) { notice("dismiss needs a reason", false); return; }
    payload.reason = reason;
    const m = $("dismiss-message").value.trim();
    if (m) payload.message = m;
  } else if (verb === "resolve") {
    const m = $("resolve-message").value.trim();
    if (!m) { notice("resolve needs a message", false); return; }
    payload.message = m;
  }
  state.busy = true;
  try {
    const res = await postAct(payload);
    notice(res.message || (res.ok ? "done" : "failed"), !!res.ok);
    if (res.ok) await refresh();
  } catch (e) {
    notice("action failed: " + e.message, false);
  } finally {
    state.busy = false;
  }
}

// ---- drafts & reports -----------------------------------------------------
function fillTable(tableId, rows, cols) {
  const tb = document.querySelector("#" + tableId + " tbody");
  tb.replaceChildren();
  rows.forEach((r) => {
    const tr = el("tr");
    cols.forEach((c) => tr.appendChild(el("td", r[c] === undefined ? "" : r[c])));
    tb.appendChild(tr);
  });
}

function renderStatus() {
  const s = state.data.status || {};
  const bits = ["week " + (s.week || "?"), "runs " + s.runs, "cost $" + s.cost];
  if (s.quota !== null && s.quota !== undefined) bits.push("claude quota " + s.quota + "%");
  if (s.codex_quota !== null && s.codex_quota !== undefined) bits.push("codex quota " + s.codex_quota + "%");
  $("status").textContent = bits.join("  |  ");
}

function renderAll() {
  fillReasons();
  renderStatus();
  renderFindings();
  fillTable("drafts-table", state.data.branches || [],
    ["repo", "branch", "date", "subject", "base", "unique_lines", "absorbed"]);
  fillTable("reports-table", state.data.reports || [],
    ["repo", "task", "lens", "date", "state", "findings", "summary"]);
}

async function refresh() {
  try {
    state.data = await getJSON("/api/inbox");
    renderAll();
    beacon("/api/client-ready?page=inbox");
  } catch (e) {
    notice("could not load inbox: " + e.message, false);
  }
}

// ---- wiring ---------------------------------------------------------------
function typing(e) {
  const t = e.target;
  if (!t || !t.tagName) return false;
  return t.tagName === "INPUT" || t.tagName === "SELECT" || t.tagName === "TEXTAREA"
    || !!(t.closest && t.closest("button"));
}

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && typing(e)) { e.target.blur(); return; }
  if (typing(e) || e.ctrlKey || e.metaKey || e.altKey || state.tab !== "findings") return;
  if (e.key === "j") move(1);
  else if (e.key === "k") move(-1);
  else if (e.key === "Enter") { if (state.sel >= 0) select(state.sel); }
  else if (e.key === "/") { e.preventDefault(); $("filter").focus(); }
});

document.querySelectorAll("#tabs button").forEach((b) => {
  b.addEventListener("click", () => showTab(b.dataset.tab));
});
$("filter").addEventListener("input", renderFindings);
$("show-decided").addEventListener("change", renderFindings);
$("act-promote").addEventListener("click", () => act("promote"));
$("act-dismiss").addEventListener("click", () => act("dismiss"));
$("act-resolve").addEventListener("click", () => act("resolve"));

refresh();
