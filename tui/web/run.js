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
  const byPath = {};
  (items || []).forEach((it) => {
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

// Button enabled flags. Unknown state (last poll failed) disables Start/Enqueue;
// Stop is never blocked by busy, only by its own in-flight call.
function buttonFlags(f) {
  const st = f.pollFailed ? null : f.state;
  const idle = st === "idle";
  return {
    enqueue: !!f.anyChecked && idle && !f.busy,
    start: idle && !f.busy,
    stop: f.pollFailed ? !f.stopBusy : st !== "idle" && !f.stopBusy,
    plan: !f.busy,
  };
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
  bar.append(mk("run-plan", "Plan"), mk("run-none", "select none"),
    mk("run-enqueue", "Enqueue selected"), mk("run-start", "Start"), mk("run-stop", "Stop"));
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
  if (!runUi.groups.length) { list.appendChild(el("p", "Nothing proposed.", "muted")); }
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
    list.appendChild(row);
  });
  const ex = plan.excluded || {};
  const note = "scan " + (plan.scan || "?") + ": discovered " + plan.discovered + ", configured "
    + plan.configured + ", unconfigured " + plan.unconfigured + ", excluded web "
    + (ex.web === undefined ? 0 : ex.web) + " / other " + (ex.other === undefined ? 0 : ex.other);
  list.appendChild(el("p", note, "muted"));
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
  });
  $("run-enqueue").disabled = !fl.enqueue;
  $("run-start").disabled = !fl.start;
  $("run-stop").disabled = !fl.stop;
  $("run-plan").disabled = !fl.plan;
}

function renderStatus(st) {
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
    renderStatus(st);
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
  const names = entries.filter((e) => e.checked).map((e) => e.repo);
  if (!names.length) return Promise.resolve();
  const ok = window.confirm("Enqueue " + names.length + " repo(s):\n" + names.join("\n")
    + "\n\nThey will be analysed by an AI model: their code leaves this machine's disk "
    + "and is sent to the model provider.\nThis replaces the currently staged queue.");
  if (!ok) return Promise.resolve();
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

function selectNone() {
  document.querySelectorAll("#run-plan-list input[type=checkbox]").forEach((b) => { b.checked = false; });
  syncButtons();
}

buildRunSection();
$("run-plan").addEventListener("click", doPlan);
$("run-none").addEventListener("click", selectNone);
$("run-enqueue").addEventListener("click", doEnqueue);
$("run-start").addEventListener("click", doStart);
$("run-stop").addEventListener("click", doStop);
syncButtons();
document.addEventListener("meute:tab", (e) => {
  if (e.detail === "run") startPolling(); else stopPolling();
});
