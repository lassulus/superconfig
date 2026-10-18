"""hermes-voice: talk to Hermes through OpenAI's full-duplex gpt-live-1.

The browser holds a WebRTC session with gpt-live-1, which listens and speaks at
the same time and chats on its own. Whenever the user asks for real work, the
voice model emits a client delegation; the page hands the recent transcript to
this server, which starts it as a Hermes run on the API server (POST /v1/runs,
one Hermes session id per conversation), follows the run's event stream and
streams the reply back. The page then gives the answer to the voice model,
which says it aloud.

A run lives independently of any HTTP connection, and this server follows
every run it started to its end, whether or not a page is still listening. A
newer delegation within the same call stops the previous run (the user
corrected or replaced the request); hanging up just ends the call, and the run
finishes whatever the user asked for. On hang-up the page sends what the user
said since the last delegation, so a request spoken right before hanging up
still reaches Hermes. When a run asks for approval while no page is listening,
the question goes to the owner's Matrix DM (the gateway's Matrix home room,
through its webhook platform), and the hermes-voice plugin's
`/assist approve|deny <code>` command answers it.

Hermes ends a call itself: when the user says goodbye, the voice model
delegates that like any request, and Hermes calls the plugin's end_call tool.
This server sees the call in the run's events and tells a listening page to
close the session once the voice has spoken the reply.

This server exists so neither secret reaches the browser: it exchanges the
page's SDP offer for a Live session with the OpenAI key, and it calls Hermes
with the API server's bearer token. That token is root-equivalent for the
Hermes host, so whoever can use this server can drive the agent: every API
route requires the page's own access token (--access-token-file), and serving
beyond loopback without one is refused.

The Android app (android/) is a second client of the same routes: it holds
the call itself (WebRTC, no page) and presents its own token
(--app-token-file), which the proxy passes through without the web login.

Vendor contract: https://developers.openai.com/api/docs/guides/live-delegation
"""

import argparse
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

log = logging.getLogger("hermes-voice")

OPENAI_BASE_URL = "https://api.openai.com/v1"
DEFAULT_MODEL = "gpt-live-1"
DEFAULT_VOICE = "marin"
# gpt-live-1 voices as OpenAI's voice picker lists them: language, regional
# influence, presentation and character, natural voices first, then the
# generated ones. The docs' voice table and the openai SDK (3.28.0) list only
# part of them; /v1/live/sessions accepts the German, French, Hindi, Japanese
# and Korean voices as well, while an unknown name is refused with 403.
BUILT_IN_VOICES = {
    "gleam": "English, North American, female: warm and conversational",
    "ripple": "English, Australian, male: warm and conversational",
    "vesper": "English, British, male: clear and direct",
    "willow": "English, Irish, female: expressive and bright",
    "stone": "English, Irish, male: calm and precise",
    "meridian": "English, North American, male: grounded and measured",
    "bossa": "Portuguese, Brazilian, female: clear and direct",
    "tempo": "Portuguese, Brazilian, male: grounded and measured",
    "cedar": "English, North American, male: open and upbeat",
    "marin": "English, North American, female: animated and earnest",
    "nuri": "German, female: warm and animated",
    "juni": "German, female: bright and expressive",
    "flitz": "German, male: rich and playful",
    "brise": "French, female: clear and conversational",
    "sillage": "French, male: warm and grounded",
    "nira": "Hindi, female: soft and thoughtful",
    "harema": "Japanese, female: gentle and engaging",
    "shida": "Japanese, male: quiet and grounded",
    "noeul": "Korean, female: airy and expressive",
    "quartz": "English, Australian, female, generated: warm and conversational",
    "alloy": "English, North American, male, generated: balanced and clear",
    "ash": "English, North American, male, generated: savvy and relaxed",
    "ballad": "English, North American, male, generated: cheerful and candid",
    "coral": "English, North American, female, generated: easygoing and versatile",
    "echo": "English, North American, male, generated: bright and inquisitive",
    "sage": "English, North American, female, generated: confident and optimistic",
    "shimmer": "English, North American, female, generated: composed and direct",
    "verse": "English, North American, male, generated: calm and affirming",
    "beacon": "English, Filipino, male, generated: clear and personable",
    "delta": "English, Southern U.S., female, generated: warm and easygoing",
    "cinder": "English, Southern U.S., male, generated: steady and grounded",
}
# gpt-live-1 bills every second a session is open, silence included; the page
# closes the session after this much inactivity.
DEFAULT_IDLE_SECONDS = 90
MAX_BODY = 256 * 1024
# The run event stream sends a keepalive every 10s, so a read that stalls this
# long means the API server is gone.
EVENTS_READ_TIMEOUT = 60
# Same cadence towards the page: a write is the only way to notice that a page
# went away while a run is quiet (e.g. waiting for an approval).
PAGE_KEEPALIVE_SECONDS = 10
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# Hermes's tool that ends the call (hermes-plugin/__init__.py).
END_CALL_TOOL = "end_call"

# Frontend persona, adapted from Hermes's own (tools/voice_live.py): role,
# style and a labelled delegation policy. The backend carries the real
# instructions, tools and memory.
PERSONA = """You are Hermes, the user's warm, upbeat and genuinely helpful voice assistant. Sound friendly and glad to help: positive and encouraging, never curt, annoyed, bored or sarcastic, even when delivering bad news or when the user is short with you. Talk fast: speak at a rapid, energetic pace, like someone who talks quickly by nature, with no slow drawn-out words and no long pauses between sentences. Keep replies short; a brief warm acknowledgment before the facts is good.

Backchannel policy: Use moderate backchannels. Acknowledge naturally without competing with the main response.

Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

Delegation policy:
Backend tools:
- Hermes agent: a full AI agent with tools. It can run commands on the user's machines, read and edit files, manage the calendar, write and read messages in the user's Matrix chat, browse the web, search, and remember things across sessions. It is the one who actually does work and knows facts.

Delegate to the backend when:
- The user asks a question that needs facts, current information, or careful reasoning.
- The user asks you to do, check, find, make, fix, run or remember anything.
- A correction changes work already requested.

- The user says goodbye, says that is all, asks you to hang up, or says they are leaving. Hermes ends the call after your reply; you may still say a short goodbye, but never end the call yourself.

Do not delegate to the backend when:
- The user greets you, makes small talk, or asks you to repeat a result already provided.
- You need a brief clarification to understand the request.

Delegate before giving an answer that depends on backend work. Do not guess the result while waiting; say briefly and cheerfully that you are on it, then wait for the result.

Approval policy:
Hermes sometimes needs the user's approval before it runs a command. When you are told so, explain in plain words what Hermes wants to do and ask whether to approve or deny it. When the user answers, delegate to the backend so the answer reaches Hermes. Never decide an approval yourself."""

# Ephemeral system prompt for every delegated Hermes turn (Hermes layers system
# messages on top of its core prompt without storing them).
BACKEND_NOTE = """This turn is a delegation from a live spoken conversation. The user message is a speech transcript: it may contain mis-hearings, phonetic spellings of technical terms, hesitations and later corrections; use the latest intent. Your reply will be spoken aloud by a friendly voice model that paraphrases it: answer in warm, plain conversational sentences, keep it short (a few sentences unless the user asked for detail), no markdown, no lists, no code blocks, no URLs read out character by character. Do the work with your tools as usual; only the final facts need to be spoken. Report an action as done only after it actually succeeded. The user may hang up before your reply is spoken: when they asked for a result or a question somewhere else, such as their Matrix chat (matrix_dm_send), send it there yourself. When the user says goodbye, says that is all, asks to hang up or says they are leaving, call end_call: only after any work they asked for has been started or handed off (for example a result promised to their Matrix chat), and never while you still need an answer from them, such as an approval. Your reply is still spoken before the call ends, so make it a short confirmation or goodbye."""

# Instead of BACKEND_NOTE for what the user said right before hanging up, when
# the voice model had not delegated it yet.
HUNG_UP_NOTE = """This turn comes from a live spoken conversation the user has already hung up. The user message is a speech transcript of what they said since the last request: it may contain mis-hearings, phonetic spellings of technical terms, hesitations and later corrections; use the latest intent. Nobody hears your reply. If the transcript asks for something, do it with your tools; when the user asked for a result somewhere, such as their Matrix chat (matrix_dm_send), send it there, and if you need something from them, ask in their Matrix chat. If it only says goodbye or thanks, or repeats a request already handled in this conversation, do nothing and reply with a short note saying so. The call is over already: do not call end_call."""


def glossary_text(glossary):
    """Glossary entries as prompt lines: `term` or `term (sounds like "…")`."""
    lines = []
    for entry in glossary:
        if isinstance(entry, str):
            lines.append(f"- {entry}")
        else:
            term = entry["term"]
            spoken = entry.get("spoken")
            lines.append(f'- {term} (sounds like "{spoken}")' if spoken else f"- {term}")
    return "\n".join(lines)


class Config:
    def __init__(self, raw, openai_key, hermes_url, hermes_key, matrix_webhook=None):
        self.matrix_webhook = matrix_webhook
        self.model = raw.get("model", DEFAULT_MODEL)
        self.voice = raw.get("voice", DEFAULT_VOICE)
        self.idle_seconds = int(raw.get("idle_seconds", DEFAULT_IDLE_SECONDS))
        self.glossary = raw.get("glossary", [])
        self.extra_instructions = raw.get("instructions", "").strip()
        self.openai_key = openai_key
        self.hermes_url = hermes_url.rstrip("/")
        self.hermes_key = hermes_key

    def live_instructions(self):
        parts = [PERSONA]
        if self.glossary:
            parts.append(
                "Technical terms the user says often. Understand them when spoken and "
                "say them like this:\n" + glossary_text(self.glossary)
            )
        if self.extra_instructions:
            parts.append(self.extra_instructions)
        return "\n\n".join(parts)

    def backend_note(self, hung_up=False):
        note = HUNG_UP_NOTE if hung_up else BACKEND_NOTE
        if not self.glossary:
            return note
        return (
            note
            + "\n\nTerms the transcript may contain as phonetic misspellings:\n"
            + glossary_text(self.glossary)
        )

    def voices(self):
        """Voices the page may pick, name -> description: the built-ins plus
        the configured one (which may be a custom voice id)."""
        voices = dict(BUILT_IN_VOICES)
        voices.setdefault(self.voice, "custom voice")
        return voices


def voice_param(voice):
    # Custom voices are objects ({"id": "voice_…"}); built-ins are names.
    if voice.startswith("voice_"):
        return {"id": voice}
    return voice


def live_history(lines):
    """Seed history for a new Live session from the page's transcript lines
    (spoken dialogue only; Hermes answers were spoken through the voice)."""
    items = []
    dialogue = [line for line in lines if line.get("speaker") in ("user", "assistant")]
    for line in dialogue[-24:]:
        text = str(line.get("text", "")).strip()[:1200]
        if not text:
            continue
        if line["speaker"] == "assistant":
            content = {"type": "output_text", "text": text}
        else:
            content = {"type": "input_text", "text": text}
        items.append({"type": "message", "role": line["speaker"], "content": [content]})
    return items


def create_live_session(config, sdp, history, voice):
    session = {
        "model": config.model,
        "instructions": config.live_instructions(),
        "audio": {"output": {"voice": voice_param(voice)}},
        "delegation": {"type": "client"},
        # The page is an untrusted frontend: it may only answer delegations and
        # hang up, not rewrite the session.
        "client": {
            "data_channel": {
                "allowed_client_events": [
                    "session.commentary.append",
                    "session.thinking.append",
                    "session.close",
                ]
            }
        },
    }
    if history:
        session["input"] = history
    body = json.dumps(
        {"session": session, "transport": {"type": "webrtc", "sdp": sdp}}
    ).encode()
    request = urllib.request.Request(
        f"{OPENAI_BASE_URL}/live/sessions",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {config.openai_key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        answer = json.load(response)
    return {"session_id": answer["session"]["id"], "sdp": answer["transport"]["sdp"]}


def transcript_message(lines):
    rendered = []
    for line in lines:
        text = str(line.get("text", "")).strip()
        if text:
            who = "Assistant" if line.get("speaker") == "assistant" else "User"
            rendered.append(f"{who}: {text}")
    return "Spoken conversation since the last request, newest last:\n" + "\n".join(
        rendered
    )


def iter_sse(response):
    """Yield (event, data) pairs from a text/event-stream response."""
    event, data = None, []
    for raw in response:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if not line:
            if data:
                yield event, "\n".join(data)
            event, data = None, []
        elif line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].lstrip())
    if data:
        yield event, "\n".join(data)


def hermes_request(config, method, path, payload=None, timeout=30):
    """Open a request to the Hermes API server (the caller closes it)."""
    request = urllib.request.Request(
        f"{config.hermes_url}{path}",
        data=None if payload is None else json.dumps(payload).encode(),
        method=method,
        headers={
            "Authorization": f"Bearer {config.hermes_key}",
            "Content-Type": "application/json",
        },
    )
    return urllib.request.urlopen(request, timeout=timeout)


def hermes_call(config, method, path, payload=None):
    with hermes_request(config, method, path, payload) as response:
        return json.load(response)


def hermes_start_run(config, hermes_session, lines, hung_up=False):
    """Start one Hermes turn as a run; return its run id. Hermes queues it
    behind a run of the same session that is still going."""
    # A plain string input: Hermes then loads the history of session_id itself.
    return hermes_call(
        config,
        "POST",
        "/v1/runs",
        {
            "input": transcript_message(lines),
            "instructions": config.backend_note(hung_up),
            "session_id": hermes_session,
        },
    )["run_id"]


def hermes_follow_run(config, run_id):
    """Follow a run's events; yield NDJSON-ready dicts (tool, delta, approval,
    end_call, done, error). Leaving early only detaches: the run keeps going."""
    with hermes_request(
        config, "GET", f"/v1/runs/{run_id}/events", timeout=EVENTS_READ_TIMEOUT
    ) as response:
        for _, data in iter_sse(response):
            payload = json.loads(data)
            event = payload.get("event", "")
            if payload.get("tool") == END_CALL_TOOL:
                # The plugin's tool fails outside a voice session; the page
                # closes the call after speaking the reply.
                if event == "tool.completed" and not payload.get("error"):
                    yield {"type": "end_call"}
            elif event in ("tool.started", "tool.completed"):
                status = "running" if event == "tool.started" else "completed"
                if payload.get("error"):
                    status = "error"
                yield {"type": "tool", "status": status, "label": payload.get("tool")}
            elif event == "approval.request":
                # The run blocks until POST /v1/runs/{run_id}/approval answers.
                # Under the gateway's session authority the request is named
                # prompt_id and the answer must carry its execution_generation.
                yield {
                    "type": "approval",
                    "request_id": payload.get("request_id") or payload.get("prompt_id"),
                    "execution_generation": payload.get("execution_generation"),
                    "command": payload.get("command"),
                    "description": payload.get("description"),
                    "timeout_s": payload.get("timeout_s"),
                }
            elif event == "run.completed":
                # Only the final answer: message.delta also streams commentary.
                yield {"type": "delta", "text": payload.get("output") or ""}
                yield {"type": "done", "finish_reason": "stop"}
                return
            elif event in ("run.failed", "run.cancelled", "run.interrupted"):
                status = event.removeprefix("run.")
                error = payload.get("error") or f"Hermes run {status}"
                yield {"type": "done", "finish_reason": status, "error": error}
                return
    yield {"type": "error", "message": "Hermes event stream ended early"}


def hermes_approve(config, run_id, approval, choice):
    """Answer a pending approval of a Hermes run."""
    answer = {"choice": choice}
    if approval.get("request_id"):
        answer["request_id"] = approval["request_id"]
    if approval.get("execution_generation") is not None:
        answer["execution_generation"] = approval["execution_generation"]
    return hermes_call(config, "POST", f"/v1/runs/{run_id}/approval", answer)


def notify_matrix(config, text):
    """Post text to the owner's Matrix DM (the gateway's Matrix home room)
    through the gateway's webhook platform (a deliver_only route, signed with
    the API server key)."""
    body = json.dumps({"text": text}).encode()
    stamp = str(int(time.time()))
    signature = hmac.new(
        config.hermes_key.encode(), stamp.encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    request = urllib.request.Request(
        config.matrix_webhook,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Webhook-Timestamp": stamp,
            "X-Webhook-Signature-V2": signature,
        },
    )
    with urllib.request.urlopen(request, timeout=30):
        pass


# Live runs by run id, and the latest run per Hermes session, which a
# correction in the same call replaces.
RUNS = {}
LATEST = {}
RUNS_LOCK = threading.Lock()
# Pending approvals by short code: the page and the Matrix command answer
# with the code.
APPROVALS = {}
APPROVALS_LOCK = threading.Lock()


class Run:
    """A Hermes run this server follows to its end, page or no page. Pages
    replay its items; an approval nobody can hear goes to Matrix."""

    def __init__(self, config, hermes_session, run_id, hung_up=False):
        self.config = config
        self.hermes_session = hermes_session
        self.run_id = run_id
        self.items = []
        self.finished = False
        self.pages = 0
        self.hung_up = hung_up
        self.cond = threading.Condition()
        with RUNS_LOCK:
            RUNS[run_id] = self
            if not hung_up:
                LATEST[hermes_session] = self
        threading.Thread(target=self.follow, daemon=True).start()

    def follow(self):
        started = time.monotonic()
        tools = 0
        try:
            for item in hermes_follow_run(self.config, self.run_id):
                if item["type"] == "tool" and item["status"] == "running":
                    tools += 1
                self.add(item)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.add({"type": "error", "message": f"Hermes {error.code}: {detail}"})
        except (urllib.error.URLError, OSError, ValueError) as error:
            self.add({"type": "error", "message": f"Hermes unreachable: {error}"})
        settle_approvals(self)
        with self.cond:
            self.finished = True
            self.cond.notify_all()
        with RUNS_LOCK:
            RUNS.pop(self.run_id, None)
            if LATEST.get(self.hermes_session) is self:
                del LATEST[self.hermes_session]
        last = self.items[-1] if self.items else {}
        log.info(
            "run %s ended (%s) after %.1fs, %d tool calls",
            self.run_id,
            last.get("finish_reason") or last.get("message"),
            time.monotonic() - started,
            tools,
        )

    def add(self, item):
        # Anything after an approval request means Hermes moved on (answered,
        # or its own timeout).
        settle_approvals(self)
        if item["type"] == "approval":
            item["code"] = open_approval(self, item)
        with self.cond:
            self.items.append(item)
            self.cond.notify_all()
            unheard = not self.pages or self.hung_up
        if item["type"] == "end_call":
            # Without a page the call has ended already.
            log.info("run %s ends the call%s", self.run_id, " (no call)" if unheard else "")
        self.ask_unheard()

    def attach(self):
        with self.cond:
            self.pages += 1

    def detach(self):
        with self.cond:
            self.pages -= 1
        self.ask_unheard()

    def hang_up(self):
        with self.cond:
            self.hung_up = True
        self.ask_unheard()

    def ask_unheard(self):
        """Send a pending approval to Matrix once no call can answer it."""
        with self.cond:
            if self.pages and not self.hung_up:
                return
        with APPROVALS_LOCK:
            unasked = [
                (code, item)
                for code, (run, item) in APPROVALS.items()
                if run is self and not item.get("asked")
            ]
            for _, item in unasked:
                item["asked"] = True
        for code, item in unasked:
            ask_matrix(self.config, code, item)


def open_approval(run, item):
    with APPROVALS_LOCK:
        code = secrets.token_hex(2)
        while code in APPROVALS:
            code = secrets.token_hex(2)
        APPROVALS[code] = (run, item)
    return code


def settle_approvals(run):
    with APPROVALS_LOCK:
        for code in [code for code, (owner, _) in APPROVALS.items() if owner is run]:
            del APPROVALS[code]


def ask_matrix(config, code, item):
    if not config.matrix_webhook:
        log.info("approval %s has no listener and no Matrix webhook", code)
        return
    text = (
        "Hermes needs your approval for work from a voice call: "
        + (item.get("description") or "run a command")
    )
    if item.get("command"):
        text += f"\n```\n{item['command']}\n```"
    text += f"\nAnswer with `/assist approve {code}` or `/assist deny {code}`."
    if item.get("timeout_s"):
        text += f" Unanswered, it is denied after {round(item['timeout_s'] / 60)} minutes."
    try:
        notify_matrix(config, text)
        log.info("approval %s asked in Matrix", code)
    except (urllib.error.URLError, OSError) as error:
        log.warning("asking approval %s in Matrix failed: %s", code, error)


def stop_run(config, run_id):
    """POST /v1/runs/{run_id}/stop; failures are only logged."""
    try:
        hermes_call(config, "POST", f"/v1/runs/{run_id}/stop")
        log.info("stopped run %s", run_id)
    except (urllib.error.URLError, OSError, ValueError) as error:
        log.warning("stopping run %s failed: %s", run_id, error)


class Handler(BaseHTTPRequestHandler):
    server_version = "hermes-voice"
    config: Config
    static: Path
    access_token: "str | None" = None
    app_token: "str | None" = None

    def authorized(self, also_hermes_key=False):
        """Check the page's bearer token (or, where allowed, the API server key
        the hermes-voice plugin in the gateway holds); answer 401 when it is
        wrong."""
        if self.access_token is None:
            return True
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        accepted = [self.access_token]
        if self.app_token:
            accepted.append(self.app_token)
        if also_hermes_key:
            accepted.append(self.config.hermes_key)
        if scheme == "Bearer" and any(
            hmac.compare_digest(token.encode(), key.encode()) for key in accepted
        ):
            return True
        self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "access token required"})
        return False

    def log_message(self, format, *args):
        log.info("%s %s", self.address_string(), format % args)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            raise ValueError("bad body length")
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if self.path == "/config":
            if not self.authorized():
                return
            self.send_json(
                HTTPStatus.OK,
                {
                    "model": self.config.model,
                    "voice": self.config.voice,
                    "voices": self.config.voices(),
                    "idle_seconds": self.config.idle_seconds,
                },
            )
            return
        names = {
            "/": ("index.html", "text/html; charset=utf-8"),
            "/app.js": ("app.js", "text/javascript; charset=utf-8"),
            "/style.css": ("style.css", "text/css; charset=utf-8"),
            "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
            "/icon-192.png": ("icon-192.png", "image/png"),
            "/icon-512.png": ("icon-512.png", "image/png"),
        }
        # Query strings do not pick a different file.
        path = urllib.parse.urlsplit(self.path).path
        if path not in names or not (self.static / names[path][0]).is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        name, content_type = names[path]
        body = (self.static / name).read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.authorized(also_hermes_key=self.path == "/approve"):
            return
        try:
            request = self.read_json()
        except ValueError:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON body"})
            return
        if self.path == "/session":
            self.handle_session(request)
        elif self.path == "/delegate":
            self.handle_delegate(request)
        elif self.path == "/hangup":
            self.handle_hangup(request)
        elif self.path == "/approve":
            self.handle_approve(request)
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def handle_session(self, request):
        # The vendor's SDP parser needs the offer byte-exact (trailing CRLF too).
        sdp = request.get("sdp")
        if not isinstance(sdp, str) or not sdp.strip():
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "sdp offer required"})
            return
        try:
            voice = request.get("voice") or self.config.voice
            if voice not in self.config.voices():
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": f"unknown voice {voice!r}"})
                return
            result = create_live_session(
                self.config, sdp, live_history(request.get("history") or []), voice
            )
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:800]
            log.warning("live session creation failed: %s %s", error.code, detail)
            self.send_json(
                HTTPStatus.BAD_GATEWAY,
                {"error": f"OpenAI rejected the session ({error.code}): {detail}"},
            )
            return
        except (urllib.error.URLError, OSError, KeyError, ValueError) as error:
            log.warning("live session creation failed: %s", error)
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"OpenAI: {error}"})
            return
        self.send_json(HTTPStatus.OK, result)

    def handle_delegate(self, request):
        hermes_session = request.get("hermes_session")
        lines = request.get("lines")
        if not isinstance(hermes_session, str) or not SESSION_ID_RE.match(hermes_session):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid hermes_session"})
            return
        if not isinstance(lines, list) or not lines:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "lines required"})
            return
        # A correction within the same call (the page says so) supersedes and
        # stops the run it replaces; runs from earlier calls keep going.
        if request.get("replace") is True:
            with RUNS_LOCK:
                previous = LATEST.pop(hermes_session, None)
            if previous:
                stop_run(self.config, previous.run_id)
        try:
            run = Run(
                self.config,
                hermes_session,
                hermes_start_run(self.config, hermes_session, lines),
            )
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes unreachable: {error}"})
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        run.attach()
        try:
            sent = 0
            while True:
                with run.cond:
                    if sent == len(run.items) and not run.finished:
                        run.cond.wait(PAGE_KEEPALIVE_SECONDS)
                    new = run.items[sent:]
                    sent += len(new)
                    done = run.finished and sent == len(run.items)
                for item in new:
                    self.write_line(item)
                if done:
                    break
                if not new:
                    self.wfile.write(b"\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Only the page is gone: this server keeps following the run.
            log.info("page left run %s", run.run_id)
        finally:
            run.detach()

    def handle_hangup(self, request):
        """The call ended. No page hears this conversation's runs any more, and
        what the user said since the last delegation becomes its own run."""
        hermes_session = request.get("hermes_session")
        lines = request.get("lines") or []
        if (
            not isinstance(hermes_session, str)
            or not SESSION_ID_RE.match(hermes_session)
            or not isinstance(lines, list)
        ):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid hang-up"})
            return
        with RUNS_LOCK:
            LATEST.pop(hermes_session, None)
            runs = [run for run in RUNS.values() if run.hermes_session == hermes_session]
        for run in runs:
            run.hang_up()
        if not any(line.get("speaker") == "user" for line in lines):
            self.send_json(HTTPStatus.OK, {"run_id": None})
            return
        try:
            run_id = hermes_start_run(self.config, hermes_session, lines, hung_up=True)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes unreachable: {error}"})
            return
        Run(self.config, hermes_session, run_id, hung_up=True)
        log.info("hang-up of %s left a request: run %s", hermes_session, run_id)
        self.send_json(HTTPStatus.OK, {"run_id": run_id})

    def handle_approve(self, request):
        code = request.get("code")
        choice = request.get("choice")
        # No "always": a permanent allowlist entry is not a voice decision.
        if choice not in ("once", "session", "deny") or not (
            code is None or isinstance(code, str)
        ):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid approval answer"})
            return
        with APPROVALS_LOCK:
            if code is None and len(APPROVALS) == 1:
                code = next(iter(APPROVALS))
            pending = APPROVALS.get(code)
        if pending is None:
            self.send_json(
                HTTPStatus.CONFLICT,
                {"error": f"no pending approval {code}" if code else "no single pending approval"},
            )
            return
        run, item = pending
        try:
            result = hermes_approve(self.config, run.run_id, item, choice)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes unreachable: {error}"})
            return
        with APPROVALS_LOCK:
            APPROVALS.pop(code, None)
        if result.get("status") == "already_resolved":
            self.send_json(HTTPStatus.CONFLICT, {"error": f"approval {code} was already answered"})
            return
        log.info("approval %s (run %s): %s %s", code, run.run_id, choice, result.get("status"))
        self.send_json(
            HTTPStatus.OK,
            {"code": code, "choice": choice, "description": item.get("description")},
        )

    def write_line(self, item):
        self.wfile.write(json.dumps(item).encode() + b"\n")
        self.wfile.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--listen", default="127.0.0.1:8790", help="host:port to serve on")
    parser.add_argument("--hermes-url", required=True, help="Hermes API server base URL")
    parser.add_argument("--hermes-key-file", required=True, help="file holding API_SERVER_KEY")
    parser.add_argument("--openai-key-file", required=True, help="file holding the OpenAI API key")
    parser.add_argument("--access-token-file", help="file holding the token the page must present")
    parser.add_argument("--app-token-file", help="file holding the token the Android app presents")
    parser.add_argument(
        "--matrix-webhook",
        help="Hermes webhook route (deliver_only to Matrix, signed with API_SERVER_KEY) that "
        "receives approvals no call can answer",
    )
    parser.add_argument("--config", help="JSON file: voice, model, idle_seconds, glossary, instructions")
    parser.add_argument(
        "--static",
        default=os.environ.get("HERMES_VOICE_STATIC"),
        help="directory with index.html, app.js, style.css (default: $HERMES_VOICE_STATIC)",
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    host, _, port = args.listen.rpartition(":")
    host = host.strip("[]")
    if args.access_token_file is None and host not in ("127.0.0.1", "::1", "localhost"):
        parser.error("--access-token-file is required when not listening on loopback")

    raw = json.loads(Path(args.config).read_text()) if args.config else {}
    config = Config(
        raw,
        openai_key=Path(args.openai_key_file).read_text().strip(),
        hermes_url=args.hermes_url,
        hermes_key=Path(args.hermes_key_file).read_text().strip(),
        matrix_webhook=args.matrix_webhook,
    )
    Handler.config = config
    Handler.static = Path(args.static)
    if args.access_token_file:
        Handler.access_token = Path(args.access_token_file).read_text().strip()
    if args.app_token_file:
        Handler.app_token = Path(args.app_token_file).read_text().strip()
    server_class = ThreadingHTTPServer
    if ":" in host:
        # "::" is dual-stack on Linux (bindv6only=0).
        server_class = type("Server6", (ThreadingHTTPServer,), {"address_family": socket.AF_INET6})
    server = server_class((host, int(port)), Handler)
    server.daemon_threads = True
    log.info("serving on http://%s", args.listen)
    server.serve_forever()


if __name__ == "__main__":
    main()
