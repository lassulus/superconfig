"use strict";

const $ = (id) => document.getElementById(id);
const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
const localNow = () => performance.timeOrigin + performance.now();

// NTP-style: trust the samples with the lowest round trip of a sliding window
const clock = { offset: 0, rtt: Infinity, samples: [] };
const serverNow = () => localNow() + clock.offset;

async function sampleClock() {
  const t0 = localNow();
  const res = await fetch("api/time", { cache: "no-store" });
  const server = parseFloat(await res.text());
  const t1 = localNow();
  clock.samples = [
    ...clock.samples,
    { rtt: t1 - t0, offset: server - (t0 + t1) / 2 },
  ].slice(-30);
  const best = [...clock.samples].sort((x, y) => x.rtt - y.rtt).slice(0, 3);
  clock.offset = best.reduce((sum, s) => sum + s.offset, 0) / best.length;
  clock.rtt = best[0].rtt;
}

let entries = [];
let pending = [];
async function loadSchedule() {
  try {
    const schedule = await (
      await fetch("api/schedule", { cache: "no-store" })
    ).json();
    entries = schedule.entries;
    pending = schedule.pending;
    updateInfo();
  } catch (e) {
    console.warn("schedule", e);
  }
}
const entryAt = (t) =>
  entries.find((e) => e.start <= t && t < e.start + e.duration);
const entryAfter = (t) => entries.find((e) => e.start > t);

// err: smoothed sync error in ms (positive: ahead of the server),
// frame: error of the frame on screen, seekLead/startLead: how far ahead to
// seek and to start the next item, learned from the error after each one
const sync = {
  err: null,
  raw: null,
  frame: null,
  seekLead: 0.2,
  startLead: 0.05,
  learn: "seekLead",
  framesSinceSeek: Infinity,
  rateSetAt: 0,
  // nudge: time and size of the largest error since the rate left 1; correctiveSeekAt: last seek done by control
  nudge: null,
  rateWorks: true,
  correctiveSeekAt: 0,
  needsStart: false,
};
let active = $("a");
let standby = $("b");
let started = false;
let swapTimer = null;

function load(video, e) {
  video.entry = e;
  video.src = "media/" + encodeURIComponent(e.file);
  video.playbackRate = 1;
}

function seek(video) {
  video.playbackRate = 1;
  video.currentTime = Math.max(
    0,
    (serverNow() - video.entry.start) / 1000 + sync.seekLead,
  );
  sync.err = null;
  sync.frame = null;
  sync.nudge = null;
  sync.framesSinceSeek = 0;
  sync.learn = "seekLead";
}

function control(raw, at) {
  sync.raw = raw;
  if (sync.framesSinceSeek < 10) {
    // the first frames after a seek or start still settle; the 10th shows how late it landed
    if (++sync.framesSinceSeek === 10) {
      const max = sync.learn === "seekLead" ? 2 : 0.5;
      sync[sync.learn] = clamp(sync[sync.learn] - raw / 1000, 0, max);
    }
    return;
  }
  if (Math.abs(raw) > 500) {
    seek(active);
    return;
  }
  const canSeek = at - sync.correctiveSeekAt > 10000;
  // browsers clock picture and sound separately and they can drift apart; a seek realigns both
  if (canSeek && sync.frame !== null && Math.abs(sync.frame - raw) > 100) {
    sync.correctiveSeekAt = at;
    seek(active);
    return;
  }
  sync.err = sync.err === null ? raw : sync.err + 0.1 * (raw - sync.err);
  if (!sync.rateWorks) {
    if (canSeek && Math.abs(sync.err) > 80) {
      sync.correctiveSeekAt = at;
      seek(active);
    }
    return;
  }
  // 5 s after its peak, a nudged error should be at least halved; some browsers ignore the rate
  if (
    active.playbackRate !== 1 &&
    (!sync.nudge || Math.abs(sync.err) > Math.abs(sync.nudge.err))
  )
    sync.nudge = { at, err: sync.err };
  if (
    sync.nudge &&
    at - sync.nudge.at > 5000 &&
    Math.abs(sync.err) > Math.abs(sync.nudge.err) / 2
  ) {
    sync.rateWorks = false;
    sync.correctiveSeekAt = at;
    seek(active);
    return;
  }
  // start nudging only past 25 ms and stop below 5 ms, so the rate does not flip back and forth around one threshold
  const rate =
    Math.abs(sync.err) < (active.playbackRate === 1 ? 25 : 5)
      ? 1
      : Math.round((1 - clamp(sync.err * 0.0005, -0.05, 0.05)) * 1000) / 1000;
  // every rate change makes playback stall a little, so change it at most twice a second
  if (rate !== active.playbackRate && at - sync.rateSetAt > 500) {
    if (rate === 1) sync.nudge = null;
    active.playbackRate = rate;
    sync.rateSetAt = at;
  }
}

// currentTime follows the media (audio) clock continuously, mediaTime only in
// whole frames, so the clock steers and the frame error is only shown
function measure() {
  if (active.entry && !active.paused && !active.seeking) {
    const now = performance.now();
    const target =
      performance.timeOrigin + now + clock.offset - active.entry.start;
    control(active.currentTime * 1000 - target, now);
  }
}

function onFrame(video, meta) {
  if (video === active && video.entry) {
    const target =
      performance.timeOrigin +
      meta.expectedDisplayTime +
      clock.offset -
      video.entry.start;
    sync.frame = meta.mediaTime * 1000 - target;
    measure();
  }
  video.requestVideoFrameCallback((_, m) => onFrame(video, m));
}

function pollPosition() {
  measure();
  requestAnimationFrame(pollPosition);
}

function swap() {
  [active, standby] = [standby, active];
  active.classList.remove("standby");
  standby.classList.add("standby");
  active.playbackRate = 1;
  active.play().catch(() => {});
  standby.pause();
  standby.removeAttribute("src");
  standby.load();
  standby.entry = null;
  sync.err = null;
  sync.frame = null;
  sync.nudge = null;
  sync.framesSinceSeek = 0;
  sync.learn = "startLead";
}

function tick() {
  if (!started) return;
  // the next item starts startLead early, so it is on time once playing
  const now = serverNow() + sync.startLead * 1000;
  const cur = entryAt(now);
  $("warmup").hidden = !!cur;
  if (!cur) {
    active.pause();
    return;
  }
  // skips and insertions move entries while an element holds them
  for (const v of [active, standby])
    v.entry = entries.find((e) => e.file === v.entry?.file) ?? v.entry;
  if (active.entry?.file !== cur.file) {
    if (standby.entry?.file === cur.file) {
      swap();
      // a skip can make the next item start before this client saw it, which must not teach startLead
      if (now - cur.start > 500) seek(active);
    } else {
      load(active, cur);
      sync.needsStart = true;
    }
    showInfo();
  }
  if (sync.needsStart && active.readyState >= HTMLMediaElement.HAVE_METADATA) {
    sync.needsStart = false;
    seek(active);
    active.play().catch(() => {});
  } else if (!sync.needsStart && active.paused && !active.ended) {
    active.play().catch(() => {});
  }
  const next = entryAfter(now);
  if (next && standby.entry?.file !== next.file) load(standby, next);
  if (next && next.start - now < 200 && !swapTimer) {
    swapTimer = setTimeout(
      () => {
        swapTimer = null;
        tick();
      },
      next.start - now + 1,
    );
  }
}

let infoTimer = null;
function updateInfo() {
  const now = serverNow() + sync.startLead * 1000;
  const cur = entryAt(now);
  const next = entryAfter(now);
  const at = (t) =>
    new Date(t).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  $("now").textContent = cur ? cur.title : "";
  $("next").textContent = next
    ? `Next at ${at(next.start)}: ${next.title}`
    : "";
  $("pending").replaceChildren(
    ...pending.map((r) => {
      const div = document.createElement("div");
      div.textContent =
        r.state === "failed"
          ? `Failed: ${r.title}: ${r.error}`
          : `${r.state === "preparing" ? "Preparing" : "Waiting"}: ${r.title}`;
      return div;
    }),
  );
  $("info").hidden = !cur && pending.length === 0;
}

function showInfo() {
  updateInfo();
  for (const el of [$("info"), $("controls")]) el.classList.remove("faded");
  clearTimeout(infoTimer);
  infoTimer = setTimeout(() => {
    for (const el of [$("info"), $("controls")]) el.classList.add("faded");
  }, 6000);
}

async function queueURL(ev) {
  ev.preventDefault();
  $("queued").textContent = "Checking…";
  try {
    const res = await fetch("api/queue", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: $("url").value }),
    });
    const out = await res.json();
    if (!res.ok) throw new Error(out.error);
    $("queued").textContent = `Queued: ${out.title}`;
    $("url").value = "";
    loadSchedule();
  } catch (e) {
    $("queued").textContent = `Error: ${e.message}`;
  }
}

function toggleFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen();
  else document.documentElement.requestFullscreen?.().catch(() => {});
}

function showDebug() {
  const ms = (x) => (x === null || !isFinite(x) ? "-" : x.toFixed(1));
  $("debug").textContent = [
    `offset   ${ms(clock.offset)} ms`,
    `rtt      ${ms(clock.rtt)} ms`,
    `error    ${ms(sync.err)} ms (now ${ms(sync.raw)} ms, frame on screen ${ms(sync.frame)} ms)`,
    `rate     ${active.playbackRate.toFixed(3)}${sync.rateWorks ? "" : " (ignored here, seeking instead)"}`,
    `leads    seek ${ms(sync.seekLead * 1000)} ms, start ${ms(sync.startLead * 1000)} ms`,
  ].join("\n");
}

window.tv = { clock, sync, serverNow, active: () => active };

$("debug").hidden = !new URLSearchParams(location.search).has("debug");
$("start").addEventListener("click", () => {
  $("start").hidden = true;
  started = true;
  tick();
});
$("fs").addEventListener("click", toggleFullscreen);
$("add").addEventListener("click", () => {
  $("queue").hidden = !$("queue").hidden;
  if (!$("queue").hidden) $("url").focus();
});
$("queue").addEventListener("submit", queueURL);
document.addEventListener("keydown", (ev) => {
  if (ev.target === $("url")) return;
  if (ev.key === "d") $("debug").hidden = !$("debug").hidden;
  if (ev.key === "f") toggleFullscreen();
});
for (const ev of ["mousemove", "touchstart"])
  document.addEventListener(ev, showInfo, { passive: true });

if ("requestVideoFrameCallback" in HTMLVideoElement.prototype) {
  for (const v of [active, standby])
    v.requestVideoFrameCallback((_, m) => onFrame(v, m));
} else {
  requestAnimationFrame(pollPosition);
}

(async () => {
  for (let i = 0; i < 10; i++) await sampleClock().catch(() => {});
  setInterval(() => sampleClock().catch(() => {}), 3000);
  await loadSchedule();
  // often enough to see a cutover before its start lead runs out
  setInterval(loadSchedule, 2000);
  setInterval(tick, 50);
  setInterval(() => $("debug").hidden || showDebug(), 250);
})();
