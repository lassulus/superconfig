// Headless Chromium sync probe for the tv player (Node >= 22, global WebSocket).
//
//   nix run nixpkgs#nodejs -- sync-probe.js <chromium> "<tv url>/?debug" <scratch dir> <scenario> [kbit/s] [latency ms]
//
// Run the tv binary locally first with a scratch config whose schedule has an
// item playing in the middle (state.json with one entry that started a few
// minutes ago). The browser loads the page through a proxy on port 8378 (or
// $PROXY_PORT; DevTools on 9333 or $CDP_PORT) that can throttle, delay and
// hold back the media. Scenarios:
//
//   normal        knock playback 60 ms off and watch it converge, then offset
//                 the picture clock (rVFC mediaTime) by 300 ms for 25 s to
//                 simulate picture drifting from sound
//   rate-ignored  the same in a browser that ignores playbackRate
//   hiccup        hold back the media in the middle of the item until
//                 playback stalls, and 2 s more, then watch for 60 s
//   stall         like the phone test: count the seeks of the first 45 s
//                 (joining), then twice hold back the media until playback
//                 stalls, 2 s more, and count the seeks of the 45 s after
//                 releasing it; reports the error after each 45 s and how
//                 long after the release playback was last out of sync
//                 (over 100 ms off, or waiting)
//   freeze        stop the browser's processes for 1.5 s in the middle of
//                 the item, like a phone busy elsewhere, then watch for 60 s
//   background    like pressing Home on the phone: hide the page for 15 s
//                 (another tab in front) and pause the video while hidden
//                 (on hiding and on every play), as Chrome on Android did
//                 in one test, then bring it back and watch for 30 s;
//                 counts the player's play()/pause() calls and the seeks
//                 while hidden and after the return, the error 1-30 s after
//                 it and when playback was last out of sync (over 100 ms
//                 off, paused or waiting)
//   background-once  the same, but the browser pauses the video only once
//                 on hiding (as in other tests on the phone)
//   clock         20 s of playback measured against the server clock instead
//                 of the player's own target: median and spread; with
//                 ?latency=MS in the page URL it should be MS ahead
//
// Run the browser through `taskset -c 0` to make its decoder slow like a
// phone's.
//
// The optional kbit/s throttles all media requests together (both video
// elements share the link, as on a phone), so the browser buffers less ahead
// and the hiccup comes sooner; latency delays each media request, like a
// phone's network does every seek past what is loaded.
//
// Prints per phase the player's seeks (currentTime writes other than the
// probe's own), the browser's seeking events, the seconds of downloaded media
// forward seeks jumped over (wasted download) and the media bytes the proxy
// passed, then the media events.
const [chromium, url, dir, scenario = "normal", kbps, latency = 0] =
  process.argv.slice(2);
const { spawn } = require("child_process");
const http = require("http");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const upstream = new URL(url);
const bytesPerSec = kbps ? (kbps * 1000) / 8 : Infinity;
let held = false;
let mediaBytes = 0;
// when the throttled link is free again
let linkFree = 0;
http
  .createServer(async (req, res) => {
    const media = req.url.includes("/media/");
    if (media) await sleep(latency);
    const up = http.request(
      {
        host: upstream.hostname,
        port: upstream.port,
        path: req.url,
        method: req.method,
        headers: req.headers,
      },
      async (ur) => {
        res.writeHead(ur.statusCode, ur.headers);
        try {
          for await (const chunk of ur) {
            if (media) {
              while (held) await sleep(50);
              const now = Date.now();
              linkFree =
                Math.max(linkFree, now) + (chunk.length / bytesPerSec) * 1000;
              await sleep(linkFree - now);
              mediaBytes += chunk.length;
            }
            if (!res.write(chunk))
              await new Promise((r) => res.once("drain", r));
          }
          res.end();
        } catch {
          res.destroy();
        }
      },
    );
    up.on("error", () => res.destroy());
    res.on("close", () => up.destroy());
    req.pipe(up);
  })
  .listen(process.env.PROXY_PORT ?? 8378, "127.0.0.1");
const proxied = new URL(url);
proxied.port = process.env.PROXY_PORT ?? 8378;
const cdpPort = process.env.CDP_PORT ?? 9333;

const p = spawn(
  chromium,
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--autoplay-policy=no-user-gesture-required",
    `--remote-debugging-port=${cdpPort}`,
    `--user-data-dir=${dir}/prof`,
    "about:blank",
  ],
  // its own process group, so freeze can stop all of the browser's processes
  { stdio: "ignore", detached: true },
);
(async () => {
  let ws;
  for (let i = 0; i < 50; i++) {
    try {
      const t = await (await fetch(`http://127.0.0.1:${cdpPort}/json`)).json();
      ws = new WebSocket(t.find((x) => x.type === "page").webSocketDebuggerUrl);
      break;
    } catch {
      await sleep(200);
    }
  }
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0;
  const waits = {};
  ws.addEventListener("message", (m) => {
    const d = JSON.parse(m.data);
    if (waits[d.id]) waits[d.id](d);
  });
  const send = (method, params = {}) =>
    new Promise((r) => {
      const i = ++id;
      waits[i] = r;
      ws.send(JSON.stringify({ id: i, method, params }));
    });
  const ev = async (e) =>
    (await send("Runtime.evaluate", { expression: e, returnByValue: true }))
      .result?.result?.value;
  await send("Page.enable");
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `
    window.__seeks = 0; window.__probeSeeks = 0; window.__seeking = 0; window.__drift = 0; window.__log = []; window.__skipped = 0; window.__plays = 0; window.__pauses = 0;
    // the player's play() and pause() calls on the active element
    for (const [m, n] of [["play", "__plays"], ["pause", "__pauses"]]) {
      const f = HTMLMediaElement.prototype[m];
      HTMLMediaElement.prototype[m] = function () {
        if (!window.__probe && window.tv && this === tv.active()) window[n]++;
        return f.call(this);
      };
    }
    ${scenario.startsWith("background") ? `const bgPause = (v) => { if (document.hidden && !v.paused) { window.__probe = true; v.pause(); window.__probe = false; } }; document.addEventListener("visibilitychange", () => bgPause(tv.active())); ${scenario === "background" ? 'addEventListener("DOMContentLoaded", () => { for (const v of document.querySelectorAll("video")) v.addEventListener("play", () => bgPause(v)); });' : ""}` : ""}
    const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "currentTime");
    Object.defineProperty(HTMLMediaElement.prototype, "currentTime", { get() { return d.get.call(this); }, set(v) {
      if (window.__probe) window.__probeSeeks++; else window.__seeks++;
      // a forward seek throws away the downloaded part of what it jumps over
      const from = d.get.call(this);
      for (let i = 0; i < this.buffered.length; i++)
        if (v > from && this.buffered.start(i) <= from && from <= this.buffered.end(i))
          window.__skipped += Math.min(v, this.buffered.end(i)) - from;
      d.set.call(this, v);
    } });
    ${scenario === "rate-ignored" ? 'Object.defineProperty(HTMLMediaElement.prototype, "playbackRate", { get() { return this.__r ?? 1; }, set(v) { this.__r = v; } });' : ""}
    const rv = HTMLVideoElement.prototype.requestVideoFrameCallback;
    HTMLVideoElement.prototype.requestVideoFrameCallback = function (cb) { return rv.call(this, (n, m) => cb(n, { ...m, mediaTime: m.mediaTime - window.__drift })); };
    addEventListener("DOMContentLoaded", () => {
      for (const v of document.querySelectorAll("video")) {
        v.addEventListener("seeking", () => {
          if (v !== tv.active()) return;
          window.__seeking++;
          window.__log.push({ t: performance.now(), at: v.currentTime.toFixed(2), ready: v.readyState,
            buffered: [...Array(v.buffered.length).keys()].map((i) => v.buffered.start(i).toFixed(1) + "-" + v.buffered.end(i).toFixed(1)).join(" "),
            raw: tv.sync.raw?.toFixed(0), lead: tv.sync.seekLead.toFixed(3), learn: tv.sync.learn });
        });
        for (const e of ["seeked", "waiting", "playing", "play", "pause"]) v.addEventListener(e, () => v === tv.active() && window.__log.push({ t: performance.now(), event: e, at: v.currentTime.toFixed(2), ready: v.readyState, hidden: document.hidden }));
      }
    });
  `,
  });
  await send("Page.navigate", { url: proxied.href });
  await sleep(3000);
  const st = async () =>
    JSON.parse(
      await ev(
        `JSON.stringify({err: tv.sync.err?.toFixed(1), raw: tv.sync.raw?.toFixed(1), frame: tv.sync.frame?.toFixed(1), rate: tv.active().playbackRate, works: tv.sync.rateWorks, lead: tv.sync.seekLead.toFixed(3), seeks: __seeks, seeking: __seeking, skipped: __skipped, plays: __plays, pauses: __pauses, ready: tv.active().readyState, paused: tv.active().paused, hidden: document.hidden})`,
      ),
    );
  let mark = { ...(await st()), bytes: mediaBytes };
  let logFrom = 0;
  const phase = async (label) => {
    const s = { ...(await st()), bytes: mediaBytes };
    console.log(
      `${label}: player seeks ${s.seeks - mark.seeks}, seeking events ${s.seeking - mark.seeking}, play() ${s.plays - mark.plays}, pause() ${s.pauses - mark.pauses}, skipped loaded ${(s.skipped - mark.skipped).toFixed(1)} s, media ${((s.bytes - mark.bytes) / 1e6).toFixed(1)} MB`,
      JSON.stringify(s),
    );
    const log = JSON.parse(await ev(`JSON.stringify(__log)`));
    for (const l of log.slice(logFrom)) console.log("   ", JSON.stringify(l));
    logFrom = log.length;
    mark = s;
  };
  await ev(`document.getElementById("start").click()`);
  await sleep(12000);
  await phase("start (12 s)");
  if (scenario === "normal" || scenario === "rate-ignored") {
    await ev(
      `__probe = true; tv.active().currentTime = tv.active().currentTime + 0.06; __probe = false`,
    );
    await sleep(14000);
    await phase("14 s after a 60 ms knock");
    await ev(`window.__drift = 0.3`);
    await sleep(25000);
    await phase("picture 300 ms behind sound for 25 s");
  } else if (scenario === "stall") {
    await sleep(33000);
    await phase("joining (45 s)");
    for (const n of [1, 2]) {
      held = true;
      for (let i = 0; i < 1500 && (await st()).ready >= 3; i++)
        await sleep(100);
      await sleep(2000);
      held = false;
      const released = Date.now();
      let outAt = released;
      while (Date.now() - released < 45000) {
        const s = await st();
        if (s.ready < 3 || s.raw === undefined || Math.abs(s.raw) > 100)
          outAt = Date.now();
        await sleep(250);
      }
      await phase(
        `45 s after stall ${n}, last out of sync ${((outAt - released) / 1000).toFixed(1)} s after the release`,
      );
    }
  } else if (scenario === "freeze") {
    await sleep(20000);
    await phase("20 s before the freeze");
    process.kill(-p.pid, "SIGSTOP");
    await sleep(1500);
    process.kill(-p.pid, "SIGCONT");
    await sleep(60000);
    await phase("60 s after the browser froze for 1.5 s");
  } else if (scenario.startsWith("background")) {
    await sleep(20000);
    await phase("20 s before hiding");
    // a tab in front hides the page (visibilitychange, rVFC and rAF stop, timers throttle)
    const { targetId } = (
      await send("Target.createTarget", { url: "about:blank" })
    ).result;
    await sleep(15000);
    await phase("15 s hidden");
    await send("Page.bringToFront");
    await send("Target.closeTarget", { targetId });
    const back = Date.now();
    // error of the playhead against the schedule, also while paused
    const errAt = {};
    let outAt = back;
    while (Date.now() - back < 30000) {
      const s = JSON.parse(
        await ev(
          `JSON.stringify({err: tv.active().currentTime * 1000 - (tv.serverNow() - tv.active().entry.start), ready: tv.active().readyState, paused: tv.active().paused})`,
        ),
      );
      const t = Date.now() - back;
      for (const at of [1, 3, 5, 10, 20, 29])
        if (t >= at * 1000 && !(at in errAt)) errAt[at] = s.err.toFixed(0);
      if (s.ready < 3 || s.paused || Math.abs(s.err) > 100) outAt = Date.now();
      await sleep(250);
    }
    await phase(
      `30 s after the return, error ${Object.entries(errAt)
        .map(([at, e]) => `${at} s: ${e} ms`)
        .join(
          ", ",
        )}, last out of sync ${((outAt - back) / 1000).toFixed(1)} s after it`,
    );
  } else if (scenario === "clock") {
    // the playhead against the server clock, which ?latency on the page moves
    // that far ahead; only while playing
    const errs = [];
    while (errs.length < 80) {
      const s = JSON.parse(
        await ev(
          `JSON.stringify({err: tv.active().currentTime * 1000 - (tv.serverNow() - tv.active().entry.start), ready: tv.active().readyState, paused: tv.active().paused})`,
        ),
      );
      if (s.ready >= 3 && !s.paused) errs.push(s.err);
      await sleep(250);
    }
    errs.sort((a, b) => a - b);
    await phase(
      `20 s against the server clock: median ${errs[40].toFixed(1)} ms, 5-95 % ${errs[4].toFixed(1)} to ${errs[75].toFixed(1)} ms`,
    );
  } else {
    await sleep(20000);
    await phase("20 s before the hiccup");
    held = true;
    for (let i = 0; i < 1500 && (await st()).ready >= 3; i++) await sleep(100);
    await sleep(2000);
    held = false;
    await phase("media held back until 2 s into a stall");
    await sleep(60000);
    await phase("60 s after the hiccup");
  }
  try {
    process.kill(-p.pid);
  } catch {}
  process.exit(0);
})();
