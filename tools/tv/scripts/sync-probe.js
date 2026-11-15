// Headless Chromium sync probe for the tv player (Node >= 22, global WebSocket).
//
//   nix run nixpkgs#nodejs -- sync-probe.js <chromium> "<tv url>/?debug" <scratch dir> <scenario> [kbit/s] [latency ms]
//
// Run the tv binary locally first with a scratch config whose schedule has an
// item playing in the middle (state.json with one entry that started a few
// minutes ago). The browser loads the page through a proxy on port 8378 that
// can throttle, delay and hold back the media. Scenarios:
//
//   normal        knock playback 60 ms off and watch it converge, then offset
//                 the picture clock (rVFC mediaTime) by 300 ms for 25 s to
//                 simulate picture drifting from sound
//   rate-ignored  the same in a browser that ignores playbackRate
//   hiccup        hold back the media in the middle of the item until
//                 playback stalls, and 2 s more, then watch for 60 s
//   freeze        stop the browser's processes for 1.5 s in the middle of
//                 the item, like a phone busy elsewhere, then watch for 60 s
//
// Run the browser through `taskset -c 0` to make its decoder slow like a
// phone's.
//
// The optional kbit/s throttles the media, so the browser buffers less ahead
// and the hiccup comes sooner; latency delays each media request, like a
// phone's network does every seek past what is loaded.
//
// Prints the player's seeks (currentTime writes other than the probe's own)
// and the browser's seeking events per phase, and the media events.
const [chromium, url, dir, scenario = "normal", kbps, latency = 0] =
  process.argv.slice(2);
const { spawn } = require("child_process");
const http = require("http");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const upstream = new URL(url);
const bytesPerSec = kbps ? (kbps * 1000) / 8 : Infinity;
let held = false;
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
              await sleep((chunk.length / bytesPerSec) * 1000);
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
  .listen(8378, "127.0.0.1");
const proxied = new URL(url);
proxied.port = 8378;

const p = spawn(
  chromium,
  [
    "--headless=new",
    "--no-sandbox",
    "--disable-gpu",
    "--autoplay-policy=no-user-gesture-required",
    "--remote-debugging-port=9333",
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
      const t = await (await fetch("http://127.0.0.1:9333/json")).json();
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
    window.__seeks = 0; window.__probeSeeks = 0; window.__seeking = 0; window.__drift = 0; window.__log = [];
    const d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "currentTime");
    Object.defineProperty(HTMLMediaElement.prototype, "currentTime", { get() { return d.get.call(this); }, set(v) {
      if (window.__probe) window.__probeSeeks++; else window.__seeks++;
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
        for (const e of ["seeked", "waiting", "playing"]) v.addEventListener(e, () => v === tv.active() && window.__log.push({ t: performance.now(), event: e, at: v.currentTime.toFixed(2), ready: v.readyState }));
      }
    });
  `,
  });
  await send("Page.navigate", { url: proxied.href });
  await sleep(3000);
  const st = async () =>
    JSON.parse(
      await ev(
        `JSON.stringify({err: tv.sync.err?.toFixed(1), raw: tv.sync.raw?.toFixed(1), frame: tv.sync.frame?.toFixed(1), rate: tv.active().playbackRate, works: tv.sync.rateWorks, lead: tv.sync.seekLead.toFixed(3), seeks: __seeks, seeking: __seeking, ready: tv.active().readyState, paused: tv.active().paused})`,
      ),
    );
  let mark = await st();
  let logFrom = 0;
  const phase = async (label) => {
    const s = await st();
    console.log(
      `${label}: player seeks ${s.seeks - mark.seeks}, seeking events ${s.seeking - mark.seeking}`,
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
  } else if (scenario === "freeze") {
    await sleep(20000);
    await phase("20 s before the freeze");
    process.kill(-p.pid, "SIGSTOP");
    await sleep(1500);
    process.kill(-p.pid, "SIGCONT");
    await sleep(60000);
    await phase("60 s after the browser froze for 1.5 s");
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
  process.kill(-p.pid);
  process.exit(0);
})();
