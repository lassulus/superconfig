"""hermes-voice: talk to Hermes through OpenAI's full-duplex gpt-live-1.

The browser holds a WebRTC session with gpt-live-1, which listens and speaks at
the same time and chats on its own. Whenever the user asks for real work, the
voice model emits a client delegation; the page hands the recent transcript to
this server, which starts it as a Hermes run on the API server (POST /v1/runs,
one Hermes session id per conversation), follows the run's event stream and
streams the reply back. The page then gives the answer to the voice model,
which says it aloud.

A run lives independently of any HTTP connection, so a turn survives the page
going away. A newer delegation for the same conversation stops the previous
run (the user corrected or replaced the request); hanging up just ends the
call, and the run finishes whatever the user asked for.

This server exists so neither secret reaches the browser: it exchanges the
page's SDP offer for a Live session with the OpenAI key, and it calls Hermes
with the API server's bearer token. That token is root-equivalent for the
Hermes host, so whoever can use this server can drive the agent: every API
route requires the page's own access token (--access-token-file), and serving
beyond loopback without one is refused.

Vendor contract: https://developers.openai.com/api/docs/guides/live-delegation
"""

import argparse
import hmac
import json
import logging
import os
import re
import socket
import threading
import time
import urllib.error
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
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# Hermes run ids are "run_<hex>", approval request ids hex.
RUN_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,256}$")

# Frontend persona, adapted from Hermes's own (tools/voice_live.py): role,
# style and a labelled delegation policy. The backend carries the real
# instructions, tools and memory.
PERSONA = """You are Hermes, lass's warm, upbeat and genuinely helpful voice assistant. Sound friendly and glad to help: positive and encouraging, never curt, annoyed, bored or sarcastic, even when delivering bad news or when the user is short with you. Talk fast: speak at a rapid, energetic pace, like someone who talks quickly by nature, with no slow drawn-out words and no long pauses between sentences. Keep replies short; a brief warm acknowledgment before the facts is good.

Backchannel policy: Use moderate backchannels. Acknowledge naturally without competing with the main response.

Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

Delegation policy:
Backend tools:
- Hermes agent: a full AI agent with tools. It can run commands on lass's machines, read and edit files, manage the calendar, inspect the coding agents in herdr, browse the web, search, and remember things across sessions. It is the one who actually does work and knows facts.

Delegate to the backend when:
- The user asks a question that needs facts, current information, or careful reasoning.
- The user asks you to do, check, find, make, fix, run or remember anything.
- A correction changes work already requested.

Do not delegate to the backend when:
- The user greets you, makes small talk, or asks you to repeat a result already provided.
- You need a brief clarification to understand the request.

Delegate before giving an answer that depends on backend work. Do not guess the result while waiting; say briefly and cheerfully that you are on it, then wait for the result.

Approval policy:
Hermes sometimes needs the user's approval before it runs a command. When you are told so, explain in plain words what Hermes wants to do and ask whether to approve or deny it. When the user answers, delegate to the backend so the answer reaches Hermes. Never decide an approval yourself."""

# Ephemeral system prompt for every delegated Hermes turn (Hermes layers system
# messages on top of its core prompt without storing them).
BACKEND_NOTE = """This turn is a delegation from a live spoken conversation. The user message is a speech transcript: it may contain mis-hearings, phonetic spellings of technical terms, hesitations and later corrections; use the latest intent. Your reply will be spoken aloud by a friendly voice model that paraphrases it: answer in warm, plain conversational sentences, keep it short (a few sentences unless the user asked for detail), no markdown, no lists, no code blocks, no URLs read out character by character. Do the work with your tools as usual; only the final facts need to be spoken. Report an action as done only after it actually succeeded."""


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
    def __init__(self, raw, openai_key, hermes_url, hermes_key):
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

    def backend_note(self):
        if not self.glossary:
            return BACKEND_NOTE
        return (
            BACKEND_NOTE
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


def hermes_start_run(config, hermes_session, lines):
    """Start one Hermes turn as a run; return its run id."""
    # A plain string input: Hermes then loads the history of session_id itself.
    return hermes_call(
        config,
        "POST",
        "/v1/runs",
        {
            "input": transcript_message(lines),
            "instructions": config.backend_note(),
            "session_id": hermes_session,
        },
    )["run_id"]


def hermes_follow_run(config, run_id):
    """Follow a run's events; yield NDJSON-ready dicts (tool, delta, approval,
    done, error). Leaving early only detaches: the run keeps going."""
    with hermes_request(
        config, "GET", f"/v1/runs/{run_id}/events", timeout=EVENTS_READ_TIMEOUT
    ) as response:
        for _, data in iter_sse(response):
            payload = json.loads(data)
            event = payload.get("event", "")
            if event in ("tool.started", "tool.completed"):
                status = "running" if event == "tool.started" else "completed"
                if payload.get("error"):
                    status = "error"
                yield {"type": "tool", "status": status, "label": payload.get("tool")}
            elif event == "approval.request":
                # The run blocks until POST /v1/runs/{run_id}/approval answers.
                yield {
                    "type": "approval",
                    "run_id": run_id,
                    "request_id": payload.get("request_id"),
                    "command": payload.get("command"),
                    "description": payload.get("description"),
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


def hermes_approve(config, run_id, request_id, choice):
    """Answer a pending approval of a Hermes run."""
    answer = {"choice": choice}
    if request_id:
        answer["request_id"] = request_id
    return hermes_call(config, "POST", f"/v1/runs/{run_id}/approval", answer)


# The active run per Hermes session, so a newer delegation can stop it.
RUNS = {}
RUNS_LOCK = threading.Lock()


def take_run(hermes_session, run_id=None):
    """Remove and return the session's run (only if it is run_id, when given)."""
    with RUNS_LOCK:
        if run_id is None or RUNS.get(hermes_session) == run_id:
            return RUNS.pop(hermes_session, None)
        return None


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

    def authorized(self):
        """Check the page's bearer token; answer 401 when it is wrong."""
        if self.access_token is None:
            return True
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme == "Bearer" and hmac.compare_digest(
            token.encode(), self.access_token.encode()
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
        }
        if self.path not in names:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        name, content_type = names[self.path]
        body = (self.static / name).read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.authorized():
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
        # One run per conversation: a newer delegation (usually a correction)
        # supersedes and stops the previous run.
        previous = take_run(hermes_session)
        if previous:
            stop_run(self.config, previous)
        try:
            run_id = hermes_start_run(self.config, hermes_session, lines)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes unreachable: {error}"})
            return
        with RUNS_LOCK:
            RUNS[hermes_session] = run_id
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        try:
            try:
                started = time.monotonic()
                tools = 0
                for item in hermes_follow_run(self.config, run_id):
                    if item["type"] == "tool" and item["status"] == "running":
                        tools += 1
                    self.write_line(item)
                log.info(
                    "hermes turn took %.1fs (%d tool calls)", time.monotonic() - started, tools
                )
            except urllib.error.HTTPError as error:
                detail = error.read().decode("utf-8", "replace")[:400]
                self.write_line({"type": "error", "message": f"Hermes {error.code}: {detail}"})
            except (urllib.error.URLError, OSError, ValueError) as error:
                self.write_line({"type": "error", "message": f"Hermes unreachable: {error}"})
            take_run(hermes_session, run_id)
        except (BrokenPipeError, ConnectionResetError):
            # The page went away; the run keeps going and stays registered, so
            # a later delegation still supersedes it.
            log.info("delegation for %s abandoned by the page", hermes_session)

    def handle_approve(self, request):
        run_id = request.get("run_id")
        request_id = request.get("request_id")
        choice = request.get("choice")
        # No "always": a permanent allowlist entry is not a voice decision.
        if (
            choice not in ("once", "session", "deny")
            or not isinstance(run_id, str)
            or not RUN_ID_RE.match(run_id)
            or not (
                request_id is None
                or (isinstance(request_id, str) and RUN_ID_RE.match(request_id))
            )
        ):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid approval answer"})
            return
        try:
            result = hermes_approve(self.config, run_id, request_id, choice)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"Hermes unreachable: {error}"})
            return
        log.info("approval %s for run %s: %s", choice, run_id, result.get("resolved"))
        self.send_json(HTTPStatus.OK, result)

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
    )
    Handler.config = config
    Handler.static = Path(args.static)
    if args.access_token_file:
        Handler.access_token = Path(args.access_token_file).read_text().strip()
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
