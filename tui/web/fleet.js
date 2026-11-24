"use strict";

const availability = document.getElementById("availability");
const observation = document.getElementById("observation");
const controllerState = document.getElementById("controller-state");
const queue = document.getElementById("queue");
const time = document.getElementById("observed-at");
const finding = document.getElementById("finding");
let observedSince = null;

function clearObservation() {
  observedSince = null;
  observation.hidden = true;
  controllerState.textContent = "";
  queue.textContent = "";
  time.textContent = "";
  time.removeAttribute("datetime");
  finding.textContent = "";
  finding.removeAttribute("href");
}

async function refresh() {
  const started = performance.now();
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetch("/api/fleet/status", {
      cache: "no-store",
      redirect: "manual",
      signal: controller.signal,
    });
    if (response.status === 401 || response.status === 403 || response.type === "opaqueredirect") {
      clearObservation();
      availability.textContent = "Sign in to view Fleet";
      return;
    }
    if (!response.ok) throw new Error("Fleet status unavailable");
    const data = await response.json();
    const status = data.controller;
    const observedAt = new Date(data.observed_at).toISOString();
    const selected = data.finding;
    controllerState.textContent = status.state;
    queue.textContent = `${status.done} of ${status.total} done, ${status.remaining} remaining`;
    time.dateTime = observedAt;
    time.textContent = observedAt;
    finding.textContent = selected.id;
    finding.href = selected.url;
    observedSince = started;
    observation.hidden = false;
    availability.textContent = "Current controller status";
  } catch {
    availability.textContent = observation.hidden ? "Controller status unavailable" : "Controller status is stale";
  } finally {
    clearTimeout(deadline);
    setTimeout(refresh, 10000);
  }
}

setInterval(() => {
  if (observedSince !== null && performance.now() - observedSince >= 30000) {
    availability.textContent = "Controller status is stale";
  }
}, 1000);

refresh();
