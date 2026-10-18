// hermes-voice page: one WebRTC session with gpt-live-1 per "call", client
// delegation answered by Hermes through the local server (/delegate).
"use strict";

const PRICE_PER_MINUTE = 0.05;
// The voice model accepts at most 500 tokens per append; ~4 chars per token.
const APPEND_CHAR_LIMIT = 1400;
// Transcript deltas can trail the delegation event; wait for the last words.
const DELEGATION_SETTLE_MS = 400;
// Once Hermes ended the call (end_call item), the call closes when the voice
// has been quiet this long after speaking the reply, at the latest after
// END_CALL_MAX_MS.
const END_CALL_QUIET_MS = 800;
const END_CALL_MAX_MS = 30000;
const STORAGE_KEY = "hermes-voice";

const talk = document.getElementById("talk");
const statusLine = document.getElementById("status");
const costLine = document.getElementById("cost");
const logList = document.getElementById("log");
const voice = document.getElementById("voice");
const approvalBox = document.getElementById("approval");
const approvalText = document.getElementById("approval-text");
const voiceSelect = document.getElementById("voice-select");
const VOICE_KEY = "hermes-voice-voice";

// The proxy in front adds the access token to logged-in requests. Once the
// login expired it redirects to the login, which a reload follows.
async function api(path, options = {}) {
  const response = await fetch(path, { ...options, redirect: "manual" });
  if (response.type === "opaqueredirect") {
    location.reload();
    throw new Error("Login expired");
  }
  return response;
}

// Spoken answer to an approval question. Denials win, so "no, don't do it"
// never approves; anything unclear is asked again.
function classifyApproval(said) {
  if (
    /\b(no|nope|deny|denied|don'?t|do not|stop|cancel|abort|reject|nein|nicht)\b/i.test(
      said,
    )
  )
    return "deny";
  if (
    /\b(yes|yeah|yep|approve|approved|go ahead|do it|okay|ok|sure|confirm|allow|ja)\b/i.test(
      said,
    )
  )
    return "once";
  return null;
}

let settings = { idle_seconds: 90 };
let call = null;
let state = loadState();

function newConversation() {
  const day = new Date().toISOString().slice(0, 10).replaceAll("-", "");
  const rand = crypto.getRandomValues(new Uint32Array(1))[0].toString(16);
  return {
    hermesSession: `voice-${day}-${rand}`,
    lines: [],
    delegated: 0,
    billedSeconds: 0,
  };
}

function loadState() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (saved && saved.hermesSession) return saved;
  } catch (_) {
    /* fall through */
  }
  return newConversation();
}

function saveState() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function setStatus(text) {
  statusLine.textContent = text;
}

function renderCost() {
  const current = call ? call.usageSeconds : 0;
  const total = state.billedSeconds + current;
  const money = (seconds) =>
    `$${((seconds / 60) * PRICE_PER_MINUTE).toFixed(3)}`;
  const clock = (seconds) =>
    `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
  costLine.textContent = call
    ? `this call ${clock(current)} · ${money(current)} — conversation ${money(total)}`
    : `conversation ${clock(total)} · ${money(total)}`;
}

function renderLog() {
  logList.replaceChildren(
    ...state.lines.map((line) => {
      const item = document.createElement("li");
      item.className = line.speaker;
      item.textContent = line.text;
      return item;
    }),
  );
  window.scrollTo(0, document.body.scrollHeight);
}

function addLine(speaker, text) {
  state.lines.push({ speaker, text });
  saveState();
  renderLog();
}

// Deltas are appended exactly as received; a speaker change starts a new line.
function addTranscript(speaker, delta) {
  const last = state.lines.at(-1);
  if (
    last &&
    last.speaker === speaker &&
    call &&
    call.lastSpeaker === speaker
  ) {
    last.text += delta;
  } else {
    state.lines.push({ speaker, text: delta });
  }
  if (call) call.lastSpeaker = speaker;
  saveState();
  renderLog();
}

function chunks(text) {
  const clean = text.replace(/\s+/g, " ").trim();
  const out = [];
  let current = "";
  for (const sentence of clean.split(/(?<=[.!?])\s+/)) {
    if (sentence.length > APPEND_CHAR_LIMIT) {
      if (current) out.push(current);
      current = "";
      for (let i = 0; i < sentence.length; i += APPEND_CHAR_LIMIT)
        out.push(sentence.slice(i, i + APPEND_CHAR_LIMIT));
    } else if (
      current &&
      current.length + 1 + sentence.length > APPEND_CHAR_LIMIT
    ) {
      out.push(current);
      current = sentence;
    } else {
      current = current ? `${current} ${sentence}` : sentence;
    }
  }
  if (current) out.push(current);
  return out;
}

class Call {
  constructor() {
    this.usageSeconds = 0;
    this.lastActivity = Date.now();
    this.speaking = false;
    this.lastSpeaker = null;
    this.delegation = null;
    this.closed = false;
    this.closing = false;
    this.ending = null;
    this.eventCounter = 0;
  }

  async start() {
    const pc = new RTCPeerConnection();
    this.pc = pc;
    pc.addEventListener("track", (event) => {
      const stream = new MediaStream([event.track]);
      voice.srcObject = stream;
      voice.play().catch(() => {});
      this.probeSpeaking(stream);
    });
    pc.addEventListener("connectionstatechange", () => {
      if (
        pc.connectionState === "failed" ||
        pc.connectionState === "disconnected"
      )
        this.finish("connection lost");
    });

    this.mic = await navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });
    for (const track of this.mic.getAudioTracks()) pc.addTrack(track, this.mic);

    // The data channel must exist before the offer so its m-line is negotiated.
    this.events = pc.createDataChannel("oai-events");
    this.events.addEventListener("message", ({ data }) =>
      this.onEvent(JSON.parse(data)),
    );
    this.events.addEventListener("close", () =>
      this.finish("connection closed"),
    );

    await pc.setLocalDescription(await pc.createOffer());
    await this.iceGathered();

    const response = await api("/session", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sdp: pc.localDescription.sdp,
        history: state.lines,
        // Fixed per session: a new pick applies from the next call on.
        voice: voiceSelect.value,
      }),
    });
    const answer = await response.json();
    if (!response.ok)
      throw new Error(answer.error || `session failed (${response.status})`);
    this.sessionId = answer.session_id;
    await pc.setRemoteDescription({ type: "answer", sdp: answer.sdp });

    this.idleTimer = setInterval(() => this.checkIdle(), 1000);
  }

  iceGathered() {
    if (this.pc.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        if (this.pc.iceGatheringState !== "complete") return;
        clearTimeout(timer);
        resolve();
      };
      // Trickle is fine: the vendor answers with the candidates it has.
      const timer = setTimeout(resolve, 3000);
      this.pc.addEventListener("icegatheringstatechange", done);
    });
  }

  probeSpeaking(stream) {
    const context = new AudioContext();
    const analyser = context.createAnalyser();
    analyser.fftSize = 512;
    context.createMediaStreamSource(stream).connect(analyser);
    const buffer = new Uint8Array(analyser.frequencyBinCount);
    let quiet = 0;
    this.audioContext = context;
    this.probe = setInterval(() => {
      analyser.getByteTimeDomainData(buffer);
      let peak = 0;
      for (const sample of buffer)
        peak = Math.max(peak, Math.abs(sample - 128));
      quiet = peak > 6 ? 0 : quiet + 1;
      const speaking = quiet < 4;
      if (speaking) this.lastActivity = Date.now();
      if (speaking !== this.speaking) {
        this.speaking = speaking;
        talk.classList.toggle("speaking", speaking);
      }
      if (this.ending?.spoken && quiet * 100 >= END_CALL_QUIET_MS) this.close();
    }, 100);
  }

  send(event) {
    if (!this.events || this.events.readyState !== "open") return false;
    this.eventCounter += 1;
    this.events.send(
      JSON.stringify({ event_id: `evt_${this.eventCounter}`, ...event }),
    );
    return true;
  }

  onEvent(event) {
    switch (event.type) {
      case "session.started":
        setStatus("Listening");
        break;
      case "session.input_transcript.delta":
        this.lastActivity = Date.now();
        addTranscript("user", event.delta || "");
        break;
      case "session.output_transcript.delta":
        this.lastActivity = Date.now();
        addTranscript("assistant", event.delta || "");
        if (this.ending) this.ending.spoken = true;
        break;
      case "session.delegation.created":
        this.delegate(event.delegation.id);
        break;
      case "session.usage.updated":
        this.usageSeconds = event.usage?.seconds ?? this.usageSeconds;
        renderCost();
        break;
      case "error":
        addLine("error", event.error?.message || "voice model error");
        break;
      case "session.closed":
        if (event.usage?.seconds != null)
          this.usageSeconds = event.usage.seconds;
        this.finish(event.reason || "closed");
        break;
    }
  }

  async delegate(id) {
    // One Hermes turn at a time: a newer delegation (usually a correction)
    // supersedes the running one, and the server stops the old run.
    // While Hermes waits for an approval, the next delegation is the user's
    // answer, not a new request: the turn must keep running.
    if (this.approval) {
      this.answerApproval(id);
      return;
    }
    const replace = Boolean(this.delegation);
    if (this.delegation) this.delegation.controller.abort();
    const controller = new AbortController();
    const delegation = { id, controller };
    this.delegation = delegation;
    setStatus("Hermes is working…");

    await new Promise((resolve) => setTimeout(resolve, DELEGATION_SETTLE_MS));
    // A hang-up meanwhile sent these lines along itself.
    if (this.delegation !== delegation || this.closed) return;
    const fresh = state.lines
      .slice(state.delegated)
      .filter((line) => line.speaker !== "hermes" && line.speaker !== "error");
    const lines = fresh.some((line) => line.speaker === "user")
      ? fresh
      : state.lines
          .filter(
            (line) => line.speaker === "user" || line.speaker === "assistant",
          )
          .slice(-4);
    state.delegated = state.lines.length;
    saveState();

    let answer = "";
    let failure = null;
    let endCall = false;
    try {
      const response = await api("/delegate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          hermes_session: state.hermesSession,
          lines,
          replace,
        }),
        signal: controller.signal,
      });
      if (!response.ok)
        throw new Error(
          (await response.json()).error ||
            `delegate failed (${response.status})`,
        );
      const reader = response.body
        .pipeThrough(new TextDecoderStream())
        .getReader();
      let buffered = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffered += value;
        let newline;
        while ((newline = buffered.indexOf("\n")) >= 0) {
          const line = buffered.slice(0, newline);
          buffered = buffered.slice(newline + 1);
          // Blank lines are the server's keepalives.
          if (!line.trim()) continue;
          const item = JSON.parse(line);
          this.lastActivity = Date.now();
          if (item.type === "approval") {
            this.askApproval(id, item);
            continue;
          }
          // Anything after an approval request means Hermes moved on
          // (answered here, by button, or by its own timeout).
          if (this.approval) this.clearApproval();
          if (item.type === "tool" && item.status === "running") {
            setStatus(`Hermes: ${item.label}`);
            this.send({
              type: "session.thinking.append",
              delegation_id: id,
              content: `Hermes is working on it: ${item.label}`.slice(
                0,
                APPEND_CHAR_LIMIT,
              ),
            });
          } else if (item.type === "end_call") {
            endCall = true;
          } else if (item.type === "delta") {
            answer += item.text;
          } else if (item.type === "done" && item.error) {
            failure = item.error;
          } else if (item.type === "error") {
            failure = item.message;
          }
        }
      }
    } catch (error) {
      if (controller.signal.aborted) return;
      failure = String(error.message || error);
    }
    if (this.delegation !== delegation) return;
    this.delegation = null;
    this.clearApproval();
    this.lastActivity = Date.now();

    if (failure && !answer.trim()) {
      addLine("error", failure);
      this.send({
        type: "session.commentary.append",
        delegation_id: id,
        content: `The request to Hermes failed: ${failure}`.slice(
          0,
          APPEND_CHAR_LIMIT,
        ),
      });
    } else {
      const text = answer.trim() || "Hermes finished without an answer.";
      addLine("hermes", text);
      for (const chunk of chunks(text))
        this.send({
          type: "session.commentary.append",
          delegation_id: id,
          content: chunk,
        });
    }
    if (endCall) this.endAfterReply();
    else setStatus("Listening");
  }

  // Hermes ended the call: close it once the voice has spoken the reply just
  // handed over.
  endAfterReply() {
    this.ending = { spoken: false };
    this.endTimer = setTimeout(() => this.close(), END_CALL_MAX_MS);
    setStatus("Ending the call…");
  }

  askApproval(id, item) {
    this.approval = { delegationId: id, code: item.code };
    const what = item.description || "run a command";
    setStatus("Hermes needs your approval");
    addLine(
      "hermes",
      `Approval needed: ${what}${item.command ? `\n${item.command}` : ""}`,
    );
    approvalText.textContent = item.command ? `${what}: ${item.command}` : what;
    approvalBox.hidden = false;
    this.send({
      type: "session.commentary.append",
      delegation_id: id,
      content: (
        `Hermes needs the user's approval before it continues: ${what}.` +
        (item.command ? ` The command is: ${item.command}.` : "") +
        " Ask the user whether to approve or deny it."
      ).slice(0, APPEND_CHAR_LIMIT),
    });
  }

  clearApproval() {
    this.approval = null;
    approvalBox.hidden = true;
  }

  async answerApproval(id) {
    await new Promise((resolve) => setTimeout(resolve, DELEGATION_SETTLE_MS));
    const said = state.lines
      .slice(state.delegated)
      .filter((line) => line.speaker === "user")
      .map((line) => line.text)
      .join(" ");
    state.delegated = state.lines.length;
    saveState();
    const choice = classifyApproval(said);
    if (!choice) {
      this.send({
        type: "session.commentary.append",
        delegation_id: id,
        content:
          "That was not a clear answer. Ask the user again: approve or deny?",
      });
      return;
    }
    await this.respondApproval(choice, id);
  }

  async respondApproval(choice, replyId) {
    const approval = this.approval;
    if (!approval) return;
    this.clearApproval();
    setStatus(choice === "deny" ? "Denying…" : "Approving…");
    let message;
    let ok = false;
    try {
      const response = await api("/approve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: approval.code, choice }),
      });
      const result = await response.json();
      ok = response.ok;
      message = ok
        ? choice === "deny"
          ? "Denied. Hermes will not run it."
          : "Approved. Hermes is continuing."
        : `Could not send the answer to Hermes: ${result.error}`;
    } catch (error) {
      message = `Could not send the answer to Hermes: ${error.message || error}`;
    }
    addLine(ok ? "hermes" : "error", message);
    // A fast turn can finish before this reply returns; its result was
    // already handed to the voice, so an "is continuing" would be stale.
    if (ok && !this.delegation) return;
    setStatus(ok ? "Hermes is working…" : "Listening");
    this.send({
      type: "session.commentary.append",
      delegation_id: replyId || approval.delegationId,
      content: message.slice(0, APPEND_CHAR_LIMIT),
    });
  }

  checkIdle() {
    if (this.closed || this.delegation || this.speaking) return;
    if (Date.now() - this.lastActivity > settings.idle_seconds * 1000) {
      setStatus("Hanging up (idle)");
      this.close();
    }
  }

  close() {
    if (this.closed || this.closing) return;
    this.closing = true;
    if (!this.send({ type: "session.close" })) {
      this.finish("closed");
      return;
    }
    // Wait for session.closed (final usage); give up after a while.
    this.closeTimer = setTimeout(() => this.finish("close timed out"), 15000);
  }

  // Tell the server the call is over, with what the user said since the last
  // delegation: a request spoken right before hanging up still reaches
  // Hermes. keepalive lets the request outlive the page.
  hangUp() {
    const lines = state.lines
      .slice(state.delegated)
      .filter(
        (line) => line.speaker === "user" || line.speaker === "assistant",
      );
    state.delegated = state.lines.length;
    saveState();
    api("/hangup", {
      method: "POST",
      keepalive: true,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ hermes_session: state.hermesSession, lines }),
    }).catch(() => {});
  }

  finish(reason) {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.closeTimer);
    clearTimeout(this.endTimer);
    clearInterval(this.idleTimer);
    clearInterval(this.probe);
    this.hangUp();
    // Only the stream is dropped; the server keeps following the Hermes run.
    if (this.delegation) this.delegation.controller.abort();
    this.audioContext?.close().catch(() => {});
    this.mic?.getTracks().forEach((track) => track.stop());
    this.events?.close();
    this.pc?.close();
    voice.srcObject = null;
    state.billedSeconds += this.usageSeconds;
    saveState();
    if (call === this) {
      call = null;
      tellApp("ended");
    }
    talk.classList.remove("live", "speaking");
    talk.textContent = "Talk";
    talk.disabled = false;
    setStatus(`Idle (${reason})`);
    renderCost();
  }
}

async function startCall() {
  call = new Call();
  tellApp("started");
  talk.disabled = true;
  talk.classList.add("live");
  talk.textContent = "Hang up";
  setStatus("Connecting…");
  // Must run inside the click handler: mobile browsers only allow audio
  // playback started by a user gesture. Started without one (?listen), the
  // track handler's play() runs while the mic records, which Chrome allows.
  voice.play().catch(() => {});
  try {
    await call.start();
    talk.disabled = false;
  } catch (error) {
    addLine("error", String(error.message || error));
    call.finish("failed to start");
  }
}

function hangUpCall() {
  talk.disabled = true;
  setStatus("Hanging up…");
  call.close();
}

talk.addEventListener("click", () => {
  if (call) {
    hangUpCall();
    return;
  }
  startCall();
});

window.addEventListener("pagehide", () => call?.finish("page closed"));

// The Android app holds each call in Android's telephony (Telecom), so a
// headset's hang-up button reaches it; it then sends "hangup". Its first
// message, as this origin (assetlinks.json: use_as_origin), brings the port.
let appPort = null;

function tellApp(message) {
  appPort?.postMessage(message);
}

window.addEventListener("message", (event) => {
  if (event.origin !== location.origin || !event.ports[0]) return;
  appPort = event.ports[0];
  appPort.onmessage = ({ data }) => {
    if (data === "hangup" && call) hangUpCall();
  };
  // ?listen starts the call before the app's channel is up.
  if (call) tellApp("started");
});

document.getElementById("new").addEventListener("click", () => {
  if (call) call.close();
  state = newConversation();
  saveState();
  renderLog();
  renderCost();
  setStatus("Idle (new conversation)");
});

document
  .getElementById("approve")
  .addEventListener("click", () => call?.respondApproval("once", null));
document
  .getElementById("deny")
  .addEventListener("click", () => call?.respondApproval("deny", null));

voiceSelect.addEventListener("change", () =>
  localStorage.setItem(VOICE_KEY, voiceSelect.value),
);

async function loadConfig() {
  let config;
  try {
    const response = await api("/config");
    config = await response.json();
  } catch (error) {
    setStatus(`Settings not loaded: ${error.message}`);
    return;
  }
  settings = config;
  talk.disabled = false;
  setStatus("Idle");
  const saved = localStorage.getItem(VOICE_KEY);
  voiceSelect.replaceChildren(
    ...Object.entries(config.voices).map(
      ([name, description]) => new Option(`${name} — ${description}`, name),
    ),
  );
  voiceSelect.value = saved in config.voices ? saved : config.voice;
  // The Android app (and the headset button) opens /?listen: talk right away.
  // Dropped from the URL once used, so a reload does not call again.
  if (new URLSearchParams(location.search).has("listen")) {
    history.replaceState(null, "", location.pathname);
    startCall();
  }
}

loadConfig();
renderLog();
renderCost();
