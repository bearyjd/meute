"use strict";
// Run tab: review the plan, stage a queue, start/stop, watch progress.
// No decision logic here: the server decides. All dynamic text uses
// textContent (via el() from app.js, which loads first). Token: TOKEN from app.js.
const POLL_MS = 2000;
const runUi = { groups: [], timer: null, status: null, planned: false, busy: false,
  stopBusy: false, pollFailed: false, seq: 0, applied: 0, timerInFlight: false };

// PURE-BEGIN
function groupByRepo(items) {
  const order = [];
  const byPath = Object.create(null);
  (Array.isArray(items) ? items : []).forEach((it) => {
    if (!it) return;
    if (!byPath[it.path]) {
      byPath[it.path] = { repo: it.repo, path: it.path, tasks: [] };
      order.push(it.path);
    }
    byPath[it.path].tasks.push({ task: it.task, reason: it.reason, rank: it.rank });
  });
  return order.map((p) => byPath[p]);
}

function enqueuePayload(entries) {
  const paths = [];
  entries.forEach((e) => { if (e.checked && paths.indexOf(e.path) < 0) paths.push(e.path); });
  return { paths: paths };
}

function progressValues(st) {
  if (!st || !(st.total > 0)) return { max: 1, value: 0 };
  return { max: st.total, value: Math.min(st.done || 0, st.total) };
}

// A response is applied only if it is newer than the last one applied.
function shouldApply(seq, lastApplied) { return seq > lastApplied; }

// Something is staged when the last applied status has work left to do; a
// finished plan (remaining 0), an empty queue or no status at all is not.
function isStaged(st) { return !!st && st.total > 0 && st.remaining > 0; }

// Button enabled flags. Unknown state (last poll failed) disables Start/Enqueue;
// Start also needs something staged (`hint`: idle, but nothing to start).
// Stop is never blocked by busy, only by its own in-flight call.
function buttonFlags(f) {
  const st = f.pollFailed ? null : f.state;
  const idle = st === "idle";
  return {
    enqueue: !!f.anyChecked && idle && !f.busy,
    start: idle && !f.busy && !!f.staged,
    hint: idle && !f.busy && !f.staged,
    stop: f.pollFailed ? !f.stopBusy : st !== "idle" && !f.stopBusy,
    plan: !f.busy,
  };
}
// Excluded counts for the scan note; the names go in a tooltip.
function excludedSummary(ex) {
  const e = ex || {};
  const count = (v) => (Array.isArray(v) ? v.length : (typeof v === "number" ? v : 0));
  const names = (label, v) => (Array.isArray(v) && v.length ? [label + ": " + v.join(", ")] : []);
  return {
    text: "excluded web " + count(e.web) + " / other " + count(e.other),
    title: names("web", e.web).concat(names("other", e.other)).join("\n"),
  };
}

// The consent text for Enqueue: one full path per ticked repo (two repos can
// share a name), then what enqueueing means.
function enqueueConfirmText(entries) {
  const paths = enqueuePayload(entries).paths;
  return "Enqueue " + paths.length + " repo(s):\n" + paths.join("\n")
    + "\n\nThey will be analysed by an AI model: their code leaves this machine's disk "
    + "and is sent to the model provider.\nIt is added to the currently staged queue.";
}

// meute plan stages one copy per repository; the copies it collapsed, the
// diverged copies it kept and the repos it could not read are summarised
// above the list. The tooltip names what no row shows: skipped repos, copies
// of an enrolled repo (their `of` has no row) and diverged copies.
function planDedupSummary(plan) {
  const arr = (v) => (Array.isArray(v) ? v.filter((x) => x && typeof x.path === "string") : []);
  const dups = arr(plan.duplicates), skipped = arr(plan.skipped), diverged = arr(plan.diverged);
  const rows = Object.create(null);
  (Array.isArray(plan.items) ? plan.items : []).forEach((it) => { if (it) rows[it.path] = true; });
  let text = dups.length + " duplicate copies collapsed, " + skipped.length + " skipped";
  if (diverged.length) {
    text += ", " + diverged.length + (diverged.length === 1 ? " diverged copy kept" : " diverged copies kept");
  }
  const title = skipped.map((d) => "skipped (no readable history): " + d.path)
    .concat(dups.filter((d) => !rows[d.of]).map((d) => d.path + " -> " + (d.reason || d.of)))
    .concat(diverged.map((d) => d.path + " diverged from " + d.of + " (kept)"));
  return { text: text, title: title.join("\n"), skipped: skipped.map((d) => d.path) };
}

// Collapsed copies keyed by the path they are a copy of, in plan order.
function copiesByCanonical(dups) {
  const by = Object.create(null);
  (Array.isArray(dups) ? dups : []).forEach((d) => {
    if (!d || typeof d.path !== "string" || typeof d.of !== "string") return;
    (by[d.of] = by[d.of] || []).push(d.path);
  });
  return by;
}

function hiddenCopiesText(n) {
  return n + (n === 1 ? " duplicate copy hidden" : " duplicate copies hidden");
}
// PURE-END

async function runCall(method, url, body) {
  const opts = { method: method, headers: {} };
  if (method === "POST") {
    opts.headers["Content-Type"] = "application/json";
    opts.headers["X-Meute-Token"] = TOKEN;
    opts.body = JSON.stringify(body || {});
  }
  const r = await fetch(url, opts);
  let data = null;
  try { data = await r.json(); } catch (e) { data = null; }
  if (!r.ok || (data && data.ok === false)) {
    throw new Error((data && data.message) || url + " -> HTTP " + r.status);
  }
  return data;
}

function runNotice(msg, ok) {
  const n = $("run-notice");
  n.textContent = msg;
  n.className = ok ? "ok" : "err";
}

function buildRunSection() {
  const root = $("run");
  const bar = el("div", null, "toolbar");
  const mk = (id, label) => { const b = el("button", label); b.type = "button"; b.id = id; return b; };
  const hint = el("span", "", "muted");
  hint.id = "run-start-hint";
  bar.append(mk("run-plan", "Plan"), mk("run-all", "select all"), mk("run-none", "select none"),
    mk("run-enqueue", "Enqueue selected"), mk("run-start", "Start"),
    hint, mk("run-stop", "Stop"));
  const help = el("p", "Tick the repos to analyse, then Enqueue selected. Enqueueing again replaces the "
    + "staged queue (it does not add to it). Nothing is ticked by default.", "muted");
  const prog = el("div", null, "run-progress");
  const head = el("div", null, "run-head");
  head.append(el("span", "idle", "badge state-idle"), el("progress"), el("span", "0 / 0"));
  head.children[0].id = "run-badge";
  head.children[1].id = "run-bar";
  head.children[2].id = "run-count";
  prog.append(head, el("div", "", "run-current"), el("div", "", "run-reason"), el("ul", null, "run-recent"));
  prog.children[1].id = "run-current";
  prog.children[2].id = "run-reason";
  prog.children[3].id = "run-recent";
  const msg = el("div", "", null);
  msg.id = "run-notice";
  const serr = el("div", "", "err");
  serr.id = "run-status-error";
  const list = el("div", null, "run-plan-list");
  list.id = "run-plan-list";
  root.replaceChildren(bar, help, msg, serr, list, prog);
}

function renderPlan(plan) {
  runUi.groups = groupByRepo(plan.items);
  runUi.planned = true;
  const list = $("run-plan-list");
  list.replaceChildren();
  const sum = planDedupSummary(plan);
  const sumLine = el("p", sum.text, "muted");
  if (sum.title) sumLine.setAttribute("title", sum.title);
  list.appendChild(sumLine);
  if (sum.skipped.length) {
    const skippedList = el("ul", null, "muted run-skipped");
    sum.skipped.forEach((path) => skippedList.appendChild(el("li", "skipped: " + path)));
    list.appendChild(skippedList);
  }
  if (!runUi.groups.length) { list.appendChild(el("p", "Nothing proposed.", "muted")); }
  const copies = copiesByCanonical(plan.duplicates);
  runUi.groups.forEach((g, i) => {
    const box = el("input");
    box.type = "checkbox";
    box.dataset.idx = String(i);
    box.addEventListener("change", syncButtons);
    const name = el("strong", g.repo);
    const lab = el("label", null, "plan-repo");
    lab.append(box, name, el("span", " " + g.path, "muted"));
    const ul = el("ul", null, "plan-tasks");
    g.tasks.forEach((t) => ul.appendChild(el("li", t.task + (t.reason ? " - " + t.reason : ""))));
    const row = el("div", null, "plan-group");
    row.append(lab, ul);
    const hidden = Object.prototype.hasOwnProperty.call(copies, g.path) ? copies[g.path] : [];
    if (hidden.length) {
      // Text only: the paths go in the tooltip; no checkbox, so select all
      // and select none never reach a copy.
      const more = el("div", hiddenCopiesText(hidden.length), "muted plan-copies");
      more.setAttribute("title", hidden.join("\n"));
      row.appendChild(more);
    }
    list.appendChild(row);
  });
  const ex = excludedSummary(plan.excluded);
  const note = el("p", "scan " + (plan.scan || "?") + ": discovered " + plan.discovered + ", configured "
    + plan.configured + ", unconfigured " + plan.unconfigured + ", " + ex.text, "muted");
  if (ex.title) note.setAttribute("title", ex.title);
  list.appendChild(note);
  syncButtons();
}

function checkedEntries() {
  return Array.from(document.querySelectorAll("#run-plan-list input[type=checkbox]")).map((b) => ({
    path: runUi.groups[Number(b.dataset.idx)].path,
    repo: runUi.groups[Number(b.dataset.idx)].repo,
    checked: b.checked,
  }));
}

function syncButtons() {
  const fl = buttonFlags({
    state: runUi.status ? runUi.status.state : "idle", pollFailed: runUi.pollFailed,
    busy: runUi.busy, stopBusy: runUi.stopBusy, anyChecked: checkedEntries().some((e) => e.checked),
    staged: isStaged(runUi.status),
  });
  $("run-enqueue").disabled = !fl.enqueue;
  $("run-start").disabled = !fl.start;
  $("run-start-hint").textContent = fl.hint ? "nothing staged: Plan, tick repos, Enqueue first" : "";
  $("run-stop").disabled = !fl.stop;
  $("run-plan").disabled = !fl.plan;
}

function renderRunStatus(st) {
  runUi.status = st;
  const badge = $("run-badge");
  badge.textContent = st.state;
  badge.className = "badge state-" + st.state;
  const pv = progressValues(st);
  const bar = $("run-bar");
  bar.max = pv.max;
  bar.value = pv.value;
  $("run-count").textContent = (st.done || 0) + " / " + (st.total || 0)
    + (st.remaining ? " (" + st.remaining + " remaining)" : "");
  const c = st.current;
  $("run-current").textContent = c ? "current: " + c.repo + " / " + c.task + " (slot " + c.slot + ")" : "";
  $("run-reason").textContent = st.stopped_reason ? "stopped: " + st.stopped_reason : "";
  const ul = $("run-recent");
  ul.replaceChildren();
  (st.recent || []).forEach((r) => {
    const cls = "res-" + String(r.status).toLowerCase().replace(/[^a-z0-9]+/g, "-");
    ul.appendChild(el("li", [r.time, r.status, r.repo, r.task].join("  "), cls));
  });
  syncButtons();
}

async function pollStatus(fromTimer) {
  if (fromTimer) {
    if (runUi.timerInFlight) return;
    runUi.timerInFlight = true;
  }
  runUi.seq += 1;
  const mine = runUi.seq;
  try {
    const st = await runCall("GET", "/api/run/status");
    if (!shouldApply(mine, runUi.applied)) return;
    runUi.applied = mine;
    runUi.pollFailed = false;
    $("run-status-error").textContent = "";
    renderRunStatus(st);
  } catch (e) {
    if (!shouldApply(mine, runUi.applied)) return;
    runUi.applied = mine;
    runUi.pollFailed = true;
    $("run-status-error").textContent = "status unavailable: " + e.message;
    syncButtons();
  } finally {
    if (fromTimer) runUi.timerInFlight = false;
  }
}

function startPolling() {
  if (runUi.timer !== null) return;
  pollStatus();
  runUi.timer = setInterval(() => pollStatus(true), POLL_MS);
}

function stopPolling() {
  if (runUi.timer !== null) { clearInterval(runUi.timer); runUi.timer = null; }
}

async function guarded(fn) {
  if (runUi.busy) return;
  runUi.busy = true;
  syncButtons();
  try { await fn(); }
  catch (e) { runNotice(e.message, false); }
  finally { runUi.busy = false; syncButtons(); }
}

function doPlan() {
  return guarded(async () => {
    runNotice("planning...", true);
    renderPlan(await runCall("GET", "/api/plan"));
    runNotice("plan loaded; nothing is selected", true);
  });
}

function doEnqueue() {
  const entries = checkedEntries();
  if (!enqueuePayload(entries).paths.length) return Promise.resolve();
  if (!window.confirm(enqueueConfirmText(entries))) return Promise.resolve();
  return guarded(async () => {
    const res = await runCall("POST", "/api/enqueue", enqueuePayload(entries));
    runNotice(res.message || "enqueued", true);
    await pollStatus();
  });
}

function doStart() {
  const ok = window.confirm("Start the run? This spends Claude/Codex subscription quota and keeps going "
    + "until the staged queue is done, the quota floor/pause stops it, or you press Stop.");
  if (!ok) return Promise.resolve();
  return guarded(async () => {
    const res = await runCall("POST", "/api/run/start", {});
    runNotice(res.message || "started", true);
    await pollStatus();
  });
}

async function doStop() {
  if (runUi.stopBusy) return;
  runUi.stopBusy = true;
  syncButtons();
  try {
    const res = await runCall("POST", "/api/run/stop", {});
    runNotice(res.message || "stopping after the current item", true);
  } catch (e) {
    runNotice(e.message, false);
  } finally {
    runUi.stopBusy = false;
    syncButtons();
  }
  await pollStatus();
}

function setAllChecked(on) {
  document.querySelectorAll("#run-plan-list input[type=checkbox]").forEach((b) => { b.checked = on; });
  syncButtons();
}

buildRunSection();
$("run-plan").addEventListener("click", doPlan);
$("run-all").addEventListener("click", () => setAllChecked(true));
$("run-none").addEventListener("click", () => setAllChecked(false));
$("run-enqueue").addEventListener("click", doEnqueue);
$("run-start").addEventListener("click", doStart);
$("run-stop").addEventListener("click", doStop);
syncButtons();
document.addEventListener("meute:tab", (e) => {
  if (e.detail === "run") startPolling(); else stopPolling();
});
