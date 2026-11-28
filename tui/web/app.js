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
// pending: a resolve/dismiss whose outcome is unknown (lost reply, busy, 5xx);
//   Retry resends it unchanged -- same request key, revision and payload.
// review: a finding key whose decision was refused as stale; no new decision
//   on it until the operator has looked at its current state.
// selRev: the revision /api/inbox listed when the finding was selected.
const state = { data: null, rows: [], sel: -1, tab: "findings", busy: false,
  pending: null, review: null, selRev: null };

// PURE-BEGIN
// One request key per submitted decision (crypto.getRandomValues works on
// plain-http tailnet addresses too, where crypto.randomUUID does not).
function newRequestKey(rand) {
  const bytes = rand(16);
  return "web-" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

// What the page does with a resolve/dismiss answer. status is null when no
// reply arrived (network error, connection dropped).
function classifyDecision(status, body) {
  const error = body && body.error;
  if (status === 200 && body && body.ok) return "ok";
  if (status === 409 && error === "stale_revision") return "stale";
  if (status === 409 && error === "key_conflict") return "conflict";
  if (status === 409 && error === "indeterminate") return "indeterminate";
  if (error === "receipt_unreadable") return "unreadable";
  if (status === null || status === 503 || status >= 500) return "retry";
  return "invalid";
}

function receiptText(r) {
  if (!r) return "";
  return ["receipt " + r.receipt_id, r.operation + " " + r.finding_key + " -> " + r.disposition,
    "request key " + r.request_key, "revision " + r.before_revision + " -> " + r.after_revision,
    "phase " + r.phase].join("\n");
}
// PURE-END

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

// A decision POST: {status, body}; status null when no reply arrived.
async function postDecision(payload) {
  let r;
  try {
    r = await fetch("/api/act", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Meute-Token": TOKEN },
      body: JSON.stringify(payload),
    });
  } catch (e) {
    return { status: null, body: null };
  }
  let body = null;
  try { body = await r.json(); } catch (e) { body = null; }
  return { status: r.status, body: body };
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
  state.selRev = f.revision || null;
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
  if (verb === "promote") {
    if (!window.confirm("Promote " + f.report + " #" + f.n + "?")) return;
    state.busy = true;
    try {
      const res = await postAct({ verb: verb, id: f.report, n: f.n });
      notice(res.message || (res.ok ? "done" : "failed"), !!res.ok);
      if (res.ok) await refresh();
    } catch (e) {
      notice("action failed: " + e.message, false);
    } finally {
      state.busy = false;
    }
    return;
  }
  if (state.pending) { notice("retry or discard the unconfirmed decision first", false); return; }
  if (state.review === f.report + "#" + f.n) {
    notice("this finding changed: review it, then press Reviewed before deciding again", false);
    return;
  }
  if (!state.selRev) { notice("this finding has no revision yet: reload the inbox", false); return; }
  const payload = { verb: verb, id: f.report, n: f.n };
  if (verb === "dismiss") {
    const reason = $("dismiss-reason").value;
    if (!reason) { notice("dismiss needs a reason", false); return; }
    payload.reason = reason;
    const m = $("dismiss-message").value.trim();
    if (m) payload.message = m;
  } else {
    const m = $("resolve-message").value.trim();
    if (!m) { notice("resolve needs a message", false); return; }
    payload.message = m;
  }
  payload.expected_revision = state.selRev;
  payload.request_key = newRequestKey((n) => crypto.getRandomValues(new Uint8Array(n)));
  await submitDecision(payload);
}

// Send a decision (first try or Retry: the payload is never rebuilt).
async function submitDecision(payload) {
  state.busy = true;
  showPending(null);
  showReceipt(null);
  try {
    const { status, body } = await postDecision(payload);
    const kind = classifyDecision(status, body);
    const msg = (body && body.message) || (status === null ? "no reply from the server" : "HTTP " + status);
    if (kind === "ok") {
      state.pending = null;
      notice(msg, true);
      showReceipt(body.receipt);
      await refresh();
    } else if (kind === "retry") {
      state.pending = payload;
      notice("decision not confirmed: " + msg, false);
      showPending(payload);
    } else if (kind === "stale") {
      state.pending = null;
      state.review = payload.id + "#" + payload.n;
      await refresh();
      notice(msg + " (current revision " + body.current_revision + ")", false);
      showReview(true);
    } else {
      // conflict, indeterminate, unreadable, invalid: nothing to resend.
      state.pending = null;
      notice(msg, false);
      if (kind !== "invalid") await refresh();
    }
  } finally {
    state.busy = false;
  }
}

function showPending(payload) {
  $("retry-box").hidden = !payload;
  $("retry-what").textContent = payload
    ? payload.verb + " " + payload.id + " #" + payload.n + " (request key " + payload.request_key + ")" : "";
}

function showReceipt(r) {
  $("receipt").hidden = !r;
  $("receipt").textContent = receiptText(r);
}

function showReview(on) { $("review-box").hidden = !on; }

async function retryPending() {
  if (state.busy || !state.pending) return;
  await submitDecision(state.pending);
}

function discardPending() {
  state.pending = null;
  showPending(null);
  notice("unconfirmed decision discarded; the inbox shows the current state", false);
  refresh();
}

// The operator has looked at the changed finding: re-read it (new revision,
// cleared fields) so the next decision is a new one with a new key.
async function reviewed() {
  const key = state.review;
  state.review = null;
  showReview(false);
  const i = state.rows.findIndex((f) => f.report + "#" + f.n === key);
  if (i >= 0) await select(i);
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
$("act-retry").addEventListener("click", retryPending);
$("act-discard").addEventListener("click", discardPending);
$("act-reviewed").addEventListener("click", reviewed);

refresh();
