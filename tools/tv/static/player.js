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
// (learn is null if this one says nothing about the next)
const sync = {
  err: null,
  raw: null,
  frame: null,
  seekLead: 0.2,
  startLead: 0.05,
  learn: "seekLead",
  framesSinceSeek: Infinity,
  rateSetAt: 0,
  // raw error when the rate last changed
  rateSetRaw: 0,
  // nudge: time and size of the largest error since the rate left 1; correctiveSeekAt: last seek done by control
  nudge: null,
  rateWorks: true,
  correctiveSeekAt: 0,
  // seeks for errors over 500 ms in a row and when the last seek settled
  bigSeeks: 0,
  landedAt: 0,
  // while waiting for the seek target to load: when and how many seconds were still missing
  behind: null,
  needsStart: false,
  // the page came back from the background and playback is not realigned yet
  resync: false,
  playAt: -Infinity,
};
let active = $("a");
let standby = $("b");
let started = false;
let swapTimer = null;

// audio only (?audio, tv.setAudioOnly): the elements play the entries' audio copies, without subtitles
let audioOnly = new URLSearchParams(location.search).has("audio");

// chosen subtitles as {lang, label}, or null for off
let subtitleChoice = JSON.parse(localStorage.getItem("subtitles") ?? "null");

// index of the chosen track in e's subtitles, by label first, then language
function subtitleIndex(e) {
  const subs = e?.subtitles ?? [];
  if (!subtitleChoice) return -1;
  const i = subs.findIndex(
    (s) => s.lang === subtitleChoice.lang && s.label === subtitleChoice.label,
  );
  return i >= 0 ? i : subs.findIndex((s) => s.lang === subtitleChoice.lang);
}

function showSubtitles(video) {
  const i = subtitleIndex(video.entry);
  video.querySelectorAll("track").forEach((t, j) => {
    t.track.mode = i === j ? "showing" : "disabled";
  });
}
// browsers turn tracks on by themselves (caption settings, restoring the page); keep only the chosen one
for (const v of [active, standby])
  v.textTracks.addEventListener("change", () => showSubtitles(v));

function updateCC() {
  const subs = active.entry?.subtitles ?? [];
  const i = subtitleIndex(active.entry);
  $("cc").hidden = audioOnly || subs.length === 0;
  $("cc").textContent = i < 0 ? "CC: off" : `CC: ${subs[i].label}`;
}

function cycleSubtitles() {
  const subs = active.entry?.subtitles ?? [];
  const i = subtitleIndex(active.entry) + 1;
  subtitleChoice =
    i < subs.length ? { lang: subs[i].lang, label: subs[i].label } : null;
  localStorage.setItem("subtitles", JSON.stringify(subtitleChoice));
  for (const v of [active, standby]) showSubtitles(v);
  updateCC();
}

function load(video, e) {
  video.entry = e;
  // an audio copy has no frames to measure sync by
  video.playsAudio = audioOnly && !!e.audio;
  video.src =
    "media/" + encodeURIComponent(video.playsAudio ? e.audio : e.file);
  video.playbackRate = 1;
  // a track removed while showing leaves its cue drawn (Android WebView), so hide the old ones first
  for (const t of video.textTracks) t.mode = "disabled";
  // tracks follow the element's currentTime, so they stay in sync without help
  video.replaceChildren(
    ...(audioOnly ? [] : (e.subtitles ?? [])).map((s) => {
      const t = document.createElement("track");
      t.kind = "subtitles";
      t.src = "media/" + encodeURIComponent(s.file);
      t.srclang = s.lang;
      t.label = s.label;
      return t;
    }),
  );
  showSubtitles(video);
}

// reloads both elements with the other files; the active one starts again with one seek (tick)
function setAudioOnly(on) {
  if (on === audioOnly) return;
  audioOnly = on;
  for (const v of [active, standby]) if (v.entry) load(v, v.entry);
  if (active.entry) sync.needsStart = true;
  updateCC();
}

// whether [t, t + 3 s] is loaded: a seek there lands without waiting for the
// network and plays on while more arrives; 3 s covers seekLead (up to 2 s)
// and the frames until it settles, and a phone on a slow link still has 5 s
// or more loaded ahead
function loaded(video, t) {
  for (let i = 0; i < video.buffered.length; i++)
    if (video.buffered.start(i) <= t && t + 3 <= video.buffered.end(i))
      return true;
  return false;
}

// how many seconds of [t, t + 3 s] the download still has to fetch beyond what is loaded around the playhead
function missing(video, t) {
  const now = video.currentTime;
  for (let i = 0; i < video.buffered.length; i++)
    if (video.buffered.start(i) <= now && now <= video.buffered.end(i))
      return t + 3 - video.buffered.end(i);
  return Infinity;
}

// where seek goes: seekLead ahead of the schedule
const seekTarget = (video) =>
  Math.max(0, (serverNow() - video.entry.start) / 1000 + sync.seekLead);

function seek(video) {
  const t = seekTarget(video);
  // only the start seeks past what is loaded; waiting for the network says nothing about the next seek
  sync.learn = loaded(video, t) ? "seekLead" : null;
  sync.resync = false;
  video.playbackRate = 1;
  video.currentTime = t;
  sync.err = null;
  sync.frame = null;
  sync.nudge = null;
  sync.framesSinceSeek = 0;
  sync.behind = null;
}

// waiting for data after a seek landed or a start makes it late by however long that took
for (const v of [active, standby])
  v.addEventListener("waiting", () => {
    if (v === active && !v.seeking) sync.learn = null;
  });

function control(raw, at) {
  sync.raw = raw;
  if (sync.framesSinceSeek < 10) {
    // the first frames after a seek or start still settle; the 10th shows how late it landed
    if (++sync.framesSinceSeek === 10) {
      sync.landedAt = at;
      if (sync.learn) {
        const max = sync.learn === "seekLead" ? 2 : 0.5;
        sync[sync.learn] = clamp(sync[sync.learn] - raw / 1000, 0, max);
      }
    }
    return;
  }
  if (Math.abs(raw) > 500) {
    // a seek past what is loaded waits for the download and lands late, so play on until the target is
    // loaded; one within it can still land late on a slow decoder (long GOPs), so after one wait 2, 4, 8,
    // then 16 s before the next, until one lands and playback stays in sync for 10 s
    if (at - sync.landedAt < (sync.bigSeeks && 1000 * 2 ** sync.bigSeeks))
      return;
    const t = seekTarget(active);
    let go = loaded(active, t);
    if (!go) {
      // the target moves on at 1x, so the download has to outrun playback by the missing seconds; on a link
      // barely faster than the video that takes long or never ends, so every 5 s project the rest and seek
      // past what is loaded (waiting for the download once) if it would take more than 15 s longer
      const left = missing(active, t);
      if (!sync.behind) sync.behind = { at, left };
      else if (at - sync.behind.at >= 5000) {
        const gained = sync.behind.left - left;
        go = !(gained > 0 && (left / gained) * 5000 <= 15000);
        sync.behind = { at, left };
      }
    }
    if (go) {
      sync.bigSeeks = Math.min(sync.bigSeeks + 1, 4);
      seek(active);
    }
    return;
  }
  sync.behind = null;
  if (at - sync.landedAt > 10000) sync.bigSeeks = 0;
  const canSeek = at - sync.correctiveSeekAt > 10000;
  // browsers clock picture and sound separately and they can drift apart; a seek realigns both
  if (canSeek && sync.frame !== null && Math.abs(sync.frame - raw) > 100) {
    sync.correctiveSeekAt = at;
    seek(active);
    return;
  }
  // some browsers (Firefox) stall the sound for ~65 ms on every rate change, which needs another nudge and
  // another change: a drop right after one that a nudge of at most 5 % cannot explain means seek instead;
  // only a drop, a stalled sound falls behind, and not in the first second after a seek, which still settles
  if (
    sync.rateWorks &&
    at - sync.landedAt > 1000 &&
    at - sync.rateSetAt < 500 &&
    raw - sync.rateSetRaw < -40
  ) {
    sync.rateWorks = false;
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
    sync.rateSetRaw = raw;
  }
}

// currentTime follows the media (audio) clock continuously, mediaTime only in
// whole frames, so the clock steers and the frame error is only shown; while
// playback waits for data the error only grows and says nothing
function measure() {
  if (
    active.entry &&
    !active.paused &&
    !active.seeking &&
    active.readyState >= HTMLMediaElement.HAVE_FUTURE_DATA
  ) {
    const now = performance.now();
    if (sync.resync) {
      // back from the background the picture restarts and drifts from the clock; one seek on the first
      // frame realigns both, and how late it lands says nothing about the next seek
      seek(active);
      sync.learn = null;
      return;
    }
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
  if (!active.playsAudio) measure();
  requestAnimationFrame(pollPosition);
}

// an audio copy has no frames: measure on a timer, which also runs while the page is hidden
setInterval(() => active.playsAudio && measure(), 16);

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
    updateCC();
  }
  if (sync.needsStart && active.readyState >= HTMLMediaElement.HAVE_METADATA) {
    sync.needsStart = false;
    seek(active);
    active.play().catch(() => {});
  } else if (
    !sync.needsStart &&
    active.paused &&
    !active.ended &&
    // the browser pauses a hidden page's video (Chrome on Android) and pauses it again if played there;
    // play it again only once visible and at most once a second
    !document.hidden &&
    performance.now() - sync.playAt >= 1000
  ) {
    sync.playAt = performance.now();
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
  if (cur?.link) $("now").href = cur.link;
  else $("now").removeAttribute("href");
  $("next").textContent = next
    ? `Next at ${at(next.start)}: ${next.title}`
    : cur
      ? `Ends at ${at(cur.start + cur.duration)}`
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

async function suggestChannel(ev) {
  ev.preventDefault();
  $("suggested").textContent = "Checking…";
  try {
    const res = await fetch("api/channels/suggest", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: $("channel").value }),
    });
    const out = await res.json();
    if (!res.ok) throw new Error(out.error);
    // a new suggestion goes to the end of the list
    $("suggested").textContent =
      `Suggested, waiting for approval: ${out.suggestions.at(-1).title}`;
    $("channel").value = "";
  } catch (e) {
    $("suggested").textContent = `Error: ${e.message}`;
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
    `rate     ${active.playbackRate.toFixed(3)}${sync.rateWorks ? "" : " (unusable here, seeking instead)"}`,
    `leads    seek ${ms(sync.seekLead * 1000)} ms, start ${ms(sync.startLead * 1000)} ms`,
  ].join("\n");
}

window.tv = { clock, sync, serverNow, active: () => active, setAudioOnly };

$("debug").hidden = !new URLSearchParams(location.search).has("debug");
$("start").addEventListener("click", () => {
  $("start").hidden = true;
  started = true;
  tick();
});
$("fs").addEventListener("click", toggleFullscreen);
$("cc").addEventListener("click", cycleSubtitles);
$("add").addEventListener("click", () => {
  $("panel").hidden = !$("panel").hidden;
  if (!$("panel").hidden) $("url").focus();
});
$("queue").addEventListener("submit", queueURL);
$("suggest").addEventListener("submit", suggestChannel);
document.addEventListener("keydown", (ev) => {
  if (ev.target.tagName === "INPUT") return;
  if (ev.key === "d") $("debug").hidden = !$("debug").hidden;
  if (ev.key === "f") toggleFullscreen();
});
for (const ev of ["mousemove", "touchstart"])
  document.addEventListener(ev, showInfo, { passive: true });
// back from the background (Home on a phone), realign once instead of steering the restarting picture
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && started) sync.resync = true;
});

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
