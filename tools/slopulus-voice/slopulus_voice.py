"""slopulus-voice: talk to slopulus through OpenAI's full-duplex gpt-live-1.1.

The browser holds a WebRTC session with gpt-live-1.1, which listens and speaks at
the same time and chats on its own. Whenever the user asks for real work, the
voice model emits a client delegation; the page hands the recent transcript to
this server, which starts it as a task: a Hermes run on the API server in the
task's own session, follows the run's event stream and streams the reply back.
The page then gives the answer to the voice model, which says it aloud.

Every conversation has one Hermes session, the call session (the page's
hermes_session). Hermes runs the turns of one session one after the other, so
each delegation forks it (POST /api/sessions/{id}/fork) into a task session
`<call session>-t<n>` with the conversation so far and runs there: a quick
question no longer waits behind a long task. The call session itself runs
nothing; the slopulus-voice plugin appends each finished task (request and
result) to it, so the next fork sees every earlier result. A task's
instructions list the call's other tasks; one that hears a correction stops
the task it corrects (the plugin's voice_task_stop, POST /tasks/stop), never
any other one. GET /tasks lists a call's tasks.

A task lives independently of any HTTP connection, and this server follows
every task to its end, whether or not a page is still listening. Hanging up
just ends the call, and the tasks finish whatever the user asked for. On
hang-up the page sends what the user said since the last delegation, so a
request spoken right before hanging up still becomes a task, and the whole
call (both sides), which goes to the "Voice calls" room as its transcript.

Each task has its own thread in Matrix from the start: when the run begins,
the plugin posts the request as a thread root in the room for voice calls and
binds that thread to the task session, so a reply there continues the task
with its full context, also after the call. The plugin reports the thread
(POST /tasks/thread) and this server posts the task's result there, and any
approval no page can hear; the plugin's `/assist approve|deny <code>` command
answers it.

slopulus ends a call itself: when the user says goodbye, the voice model
delegates that like any request, and slopulus calls the plugin's end_call tool.
This server sees the call in the run's events and tells a listening page to
close the session once the voice has spoken the reply.

This server exists so neither secret reaches the browser: it exchanges the
page's SDP offer for a Live session with the OpenAI key, and it calls slopulus
with the API server's bearer token. That token is root-equivalent for the
agent's host, so whoever can use this server can drive the agent: every API
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

log = logging.getLogger("slopulus-voice")

OPENAI_BASE_URL = "https://api.openai.com/v1"
DEFAULT_MODEL = "gpt-live-1.1"
DEFAULT_VOICE = "marin"
# gpt-live-1.1 voices as OpenAI's voice picker lists them: language, regional
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
    "calandria": "Spanish, Argentine, female",
    "compas": "Spanish, Argentine, male",
    "hornero": "Spanish, Argentine, male",
    "luciernaga": "Spanish, Mexican, female",
    "destello": "Spanish, Mexican, male",
    "halo": "English, British, female",
    "pearl": "English, Australian, female",
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
# gpt-live-1.1 bills every second a session is open, silence included; the page
# closes the session after this much inactivity.
DEFAULT_IDLE_SECONDS = 30
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
# Every delegation runs as a task in its own Hermes session (see start_task);
# Hermes caps concurrent runs itself (gateway.api_server.max_concurrent_runs,
# 429 beyond). How long a task title (the user's words) is in the task list
# and in Matrix:
TASK_TITLE_CHARS = 60
# How many other tasks of the call a task's instructions list, and how much of
# their progress or result.
TASK_NOTE_LIMIT = 10
TASK_NOTE_RESULT_CHARS = 300
# A call's task list is dropped this long after its last use, once all its
# tasks finished.
CALL_RETENTION_SECONDS = 24 * 3600
# Task session ids taken already (left over from before a restart of this
# server) are skipped; after this many the delegation fails.
FORK_ATTEMPTS = 20

# Frontend persona, adapted from Hermes's own (tools/voice_live.py): role,
# style and a labelled delegation policy. The backend carries the real
# instructions, tools and memory.
PERSONA = """You are slopulus, the user's warm, upbeat and genuinely helpful voice assistant. Sound friendly and glad to help: positive and encouraging, never curt, annoyed, bored or sarcastic, even when delivering bad news or when the user is short with you. Talk fast: speak at a rapid, energetic pace, like someone who talks quickly by nature, with no slow drawn-out words and no long pauses between sentences. Keep replies short; a brief warm acknowledgment before the facts is good.

Backchannel policy: Use moderate backchannels. Acknowledge naturally without competing with the main response.

Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

Delegation policy:
Backend tools:
- slopulus agent: a full AI agent with tools. It can run commands on the user's machines, read and edit files, manage the calendar, write and read messages in the user's Matrix chat, browse the web, search, and remember things across sessions. It is the one who actually does work and knows facts. You yourself cannot do anything.

Delegate to the backend when:
- The user asks a question that needs facts, current information, or careful reasoning.
- The user asks you to do, check, find, make, fix, run or remember anything, or to change or control something such as lights, devices, music or messages. Delegate every single time, also when it repeats or varies something done earlier in the call.
- A correction changes work already requested.
- The user answers a question or offer from slopulus: picks one of its options, says yes or no, or approves a plan. Delegate the answer itself, also when it is a single word: slopulus acts on it only once it arrives.
- The user asks a new question or makes a new request while slopulus still works on an earlier one. Delegate it right away, without waiting for the earlier result: slopulus works on all of them at the same time, and each result comes back on its own.
- The user asks which requests are still running, or asks to stop or cancel one of them.

- The user says goodbye, says that is all, asks you to hang up, or says they are leaving. slopulus ends the call after your reply; you may still say a short goodbye, but never end the call yourself.

Do not delegate to the backend when:
- The user greets you, makes small talk, or asks you to repeat a result already provided.
- You need a brief clarification to understand the request.

Delegate before giving an answer that depends on backend work. Emit the delegation first; only together with it may you say briefly and cheerfully that you are on it, then wait for the result. Never say you are on it, promise an action ("I'll switch", "I'll set that up"), say it is done or describe the action without delegating it in the same turn. Never say slopulus is working on, looking into or waiting for something you have not delegated. Do not guess the result while waiting, and never report something as done until the backend result says so. While waiting you get notes on what slopulus is doing right now (its own words, its current tool and command); when the user asks what is taking so long or what is happening, describe only those notes in plain words, and if there is none yet, say slopulus is still working on it. Never invent what slopulus is doing. Every result also lands in the user's Matrix chat, so a result that comes in after the call still reaches them.

Approval policy:
slopulus sometimes needs the user's approval before it runs a command. When you are told so, explain in plain words what slopulus wants to do and ask whether to approve or deny it. When the user answers, delegate to the backend so the answer reaches slopulus. Never decide an approval yourself."""

# Ephemeral system prompt for every delegated Hermes turn (Hermes layers system
# messages on top of its core prompt without storing them).
BACKEND_NOTE = """This turn is a delegation from a live spoken conversation. The user message is a speech transcript: it may contain mis-hearings, phonetic spellings of technical terms, hesitations and later corrections; use the latest intent. Your reply will be spoken aloud by a friendly voice model that paraphrases it: answer in warm, plain conversational sentences, keep it short (a few sentences unless the user asked for detail), no markdown, no lists, no code blocks, no URLs read out character by character. Do the work with your tools as usual; only the final facts need to be spoken. Before each tool call, write one short plain sentence saying what you are doing now (for example: Reading the CI logs of pull request 205): the user hears it as progress while waiting. Report an action as done only after it actually succeeded. Your reply is also posted in this request's own thread in the user's Matrix room for voice calls, where they can read it and answer you later, also after hanging up; do not post it there yourself. When they asked for a result or a question somewhere else, such as their Matrix chat (matrix_dm_send), send it there yourself. When the user says goodbye, says that is all, asks to hang up or says they are leaving, call end_call: only after any work they asked for has been started or handed off (for example a result promised to their Matrix chat), and never while you still need an answer from them, such as an approval. Your reply is still spoken before the call ends, so make it a short confirmation or goodbye."""

# Instead of BACKEND_NOTE for what the user said right before hanging up, when
# the voice model had not delegated it yet.
HUNG_UP_NOTE = """This turn comes from a live spoken conversation the user has already hung up. The user message is a speech transcript of what they said since the last request: it may contain mis-hearings, phonetic spellings of technical terms, hesitations and later corrections; use the latest intent. Nobody hears your reply; it is posted in this request's own thread in the user's Matrix room for voice calls, where they can answer you. If the transcript asks for something, do it with your tools; when the user asked for a result somewhere else, such as their Matrix chat (matrix_dm_send), send it there, and if you need something from them, ask in your reply. If it only says goodbye or thanks, or repeats a request already handled or still running in this conversation, do nothing and reply with a short note saying so. The call is over already: do not call end_call."""

# Closes the task list in a task's instructions (tasks_note).
TASKS_POLICY = """When the newest request corrects, changes or cancels one of the running tasks above, stop that task with voice_task_stop (only that one, never a task the user did not mean) and do the corrected request yourself; when it only asks to stop one, stop it and confirm. When the user asks what is running or how a task is doing, answer from this list; voice_tasks gives the current state."""


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
    def __init__(
        self,
        raw,
        openai_key,
        hermes_url,
        hermes_key,
        matrix_webhook=None,
        transcript_webhook=None,
        task_webhook=None,
    ):
        self.matrix_webhook = matrix_webhook
        self.transcript_webhook = transcript_webhook or matrix_webhook
        self.task_webhook = task_webhook
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
    (spoken dialogue only; slopulus' answers were spoken through the voice)."""
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


def render_lines(lines):
    """Transcript lines as `User: …` / `Assistant: …` text, empty ones left out."""
    rendered = []
    for line in lines:
        text = str(line.get("text", "")).strip()
        if text:
            who = "Assistant" if line.get("speaker") == "assistant" else "User"
            rendered.append(f"{who}: {text}")
    return "\n".join(rendered)


def transcript_message(lines):
    return "Spoken conversation since the last request, newest last:\n" + render_lines(lines)


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


def hermes_ensure_session(config, session):
    """Create the call's Hermes session (empty) unless it exists: tasks fork it."""
    try:
        hermes_call(config, "POST", "/api/sessions", {"id": session, "title": f"Voice call {session}"})
    except urllib.error.HTTPError as error:
        if error.code != HTTPStatus.CONFLICT:
            raise


def hermes_fork(config, source, session, title):
    """Fork `source` into the new session `session`: a copy of its history
    (Hermes marks the source ended "branched"; nothing runs there anyway)."""
    hermes_call(
        config,
        "POST",
        f"/api/sessions/{urllib.parse.quote(source, safe='')}/fork",
        {"id": session, "title": title},
    )


def hermes_start_run(config, session, lines, instructions):
    """Start one Hermes turn as a run; return its run id. Hermes runs the turns
    of one session one after the other, so every task has its own session."""
    # A plain string input: Hermes then loads the history of session_id itself.
    return hermes_call(
        config,
        "POST",
        "/v1/runs",
        {
            "input": transcript_message(lines),
            "instructions": instructions,
            "session_id": session,
        },
    )["run_id"]


def hermes_follow_run(config, run_id):
    """Follow a run's events; yield NDJSON-ready dicts (tool, delta, approval,
    end_call, done, error). Leaving early only detaches: the run keeps going."""
    with hermes_request(
        config, "GET", f"/v1/runs/{run_id}/events", timeout=EVENTS_READ_TIMEOUT
    ) as response:
        # Text Hermes writes before a tool call says what it is doing now.
        note = ""
        for _, data in iter_sse(response):
            payload = json.loads(data)
            event = payload.get("event", "")
            if event == "message.delta":
                note += payload.get("delta") or ""
            elif payload.get("tool") == END_CALL_TOOL:
                # The plugin's tool fails outside a voice session; the page
                # closes the call after speaking the reply.
                if event == "tool.completed" and not payload.get("error"):
                    yield {"type": "end_call"}
            elif event in ("tool.started", "tool.completed"):
                status = "running" if event == "tool.started" else "completed"
                if payload.get("error"):
                    status = "error"
                yield {
                    "type": "tool",
                    "status": status,
                    "label": payload.get("tool"),
                    "preview": payload.get("preview") or "",
                    "note": note.strip(),
                }
                note = ""
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
                error = payload.get("error") or f"slopulus' run {status}"
                yield {"type": "done", "finish_reason": status, "error": error}
                return
    yield {"type": "error", "message": "slopulus' event stream ended early"}


def hermes_approve(config, run_id, approval, choice):
    """Answer a pending approval of a Hermes run."""
    answer = {"choice": choice}
    if approval.get("request_id"):
        answer["request_id"] = approval["request_id"]
    if approval.get("execution_generation") is not None:
        answer["execution_generation"] = approval["execution_generation"]
    return hermes_call(config, "POST", f"/v1/runs/{run_id}/approval", answer)


def notify_matrix(config, text, url=None, fields=None):
    """Post text to Matrix through the gateway's webhook platform (a
    deliver_only route, signed with the API server key): by default the
    owner's DM (the gateway's Matrix home room), or the room behind `url`.
    `fields` are further payload keys the route's template uses (thread_id)."""
    body = json.dumps({"text": text, **(fields or {})}).encode()
    stamp = str(int(time.time()))
    signature = hmac.new(
        config.hermes_key.encode(), stamp.encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    request = urllib.request.Request(
        url or config.matrix_webhook,
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


def task_title(lines):
    """A short title for a task: the user's last words of its request."""
    said = [str(line.get("text", "")).strip() for line in lines if line.get("speaker") == "user"]
    title = " ".join((said[-1] if said and said[-1] else render_lines(lines)).split())
    if len(title) > TASK_TITLE_CHARS:
        title = title[: TASK_TITLE_CHARS - 1].rstrip() + "…"
    return title or "request"


def ago(seconds):
    seconds = int(seconds)
    return f"{seconds} seconds" if seconds < 120 else f"{seconds // 60} minutes"


# Calls by their Hermes session id (the page's hermes_session, one per
# conversation) with their tasks. A call is forgotten CALL_RETENTION_SECONDS
# after its last use once all its tasks finished.
CALLS = {}
CALLS_LOCK = threading.Lock()
# Pending approvals by short code: the page and the Matrix command answer
# with the code.
APPROVALS = {}
APPROVALS_LOCK = threading.Lock()


class Call:
    def __init__(self, session):
        self.session = session
        self.tasks = {}
        self.next_number = 1
        self.session_ready = False
        self.touched = time.monotonic()


def get_call(session):
    now = time.monotonic()
    with CALLS_LOCK:
        for key in [
            key
            for key, call in CALLS.items()
            if now - call.touched > CALL_RETENTION_SECONDS
            and all(task.finished for task in call.tasks.values())
        ]:
            del CALLS[key]
        call = CALLS.setdefault(session, Call(session))
        call.touched = now
        return call


def find_task(session):
    """The task whose Hermes session is `session`, or None."""
    with CALLS_LOCK:
        for call in CALLS.values():
            for task in call.tasks.values():
                if task.session == session:
                    return task
    return None


def tasks_note(call, own):
    """The call's other tasks, for the instructions of task `own`."""
    with CALLS_LOCK:
        others = [task for task in call.tasks.values() if task.id != own]
    lines = [
        "Every request of this voice call runs as its own slopulus task in its own session, "
        f"all at the same time. You are task {own}."
    ]
    if others:
        lines.append("The other tasks of this call, oldest first:")
        lines += [task.describe() for task in others[-TASK_NOTE_LIMIT:]]
        lines.append(TASKS_POLICY)
    return "\n".join(lines)


def start_task(config, call_session, lines, hung_up=False):
    """Fork the call's session into a new task session, start the request
    there as a Hermes run and follow it; return the Task."""
    call = get_call(call_session)
    if not call.session_ready:
        hermes_ensure_session(config, call_session)
        call.session_ready = True
    title = task_title(lines)
    for _ in range(FORK_ATTEMPTS):
        with CALLS_LOCK:
            number = call.next_number
            call.next_number += 1
        task_id = f"t{number}"
        session = f"{call_session}-{task_id}"
        # Hermes titles are unique and at most 100 characters.
        try:
            hermes_fork(config, call_session, session, f"{title[: 97 - len(session)]} · {session}")
            break
        except urllib.error.HTTPError as error:
            # Left over from before a restart of this server: take the next number.
            if error.code != HTTPStatus.CONFLICT:
                raise
    else:
        raise ValueError(f"no free task session for {call_session}")
    instructions = config.backend_note(hung_up) + "\n\n" + tasks_note(call, task_id)
    run_id = hermes_start_run(config, session, lines, instructions)
    task = Task(config, call, task_id, session, title, run_id, hung_up)
    log.info("task %s started as run %s: %s", session, run_id, title)
    return task


class Task:
    """One request of a call: a Hermes run in the task's own session, which
    this server follows to its end, page or no page. Pages replay its items;
    the result and any approval nobody can hear go to the task's Matrix
    thread."""

    def __init__(self, config, call, task_id, session, title, run_id, hung_up=False):
        self.config = config
        self.call = call
        self.id = task_id
        self.session = session
        self.title = title
        self.run_id = run_id
        self.state = "running"
        self.started = time.monotonic()
        self.ended = None
        self.progress = ""
        self.result = ""
        self.thread_id = None
        self.items = [{"type": "task", "task": task_id, "title": title, "session": session}]
        self.finished = False
        self.pages = 0
        self.hung_up = hung_up
        self.cond = threading.Condition()
        with CALLS_LOCK:
            call.tasks[task_id] = self
        threading.Thread(target=self.follow, daemon=True).start()

    def info(self):
        end = self.ended or time.monotonic()
        return {
            "task": self.id,
            "title": self.title,
            "session": self.session,
            "state": self.state,
            "seconds": int(end - self.started),
            "progress": self.progress,
            "result": self.result,
        }

    def describe(self):
        """One line about this task for another task's instructions."""
        text = f'- {self.id} "{self.title}": {self.state}'
        if self.finished:
            text += f" after {ago(self.ended - self.started)}"
            if self.result:
                text += f", result: {self.result[:TASK_NOTE_RESULT_CHARS]}"
        else:
            text += f" for {ago(time.monotonic() - self.started)}"
            if self.progress:
                text += f", now: {self.progress[:TASK_NOTE_RESULT_CHARS]}"
        return text

    def follow(self):
        tools = 0
        try:
            for item in hermes_follow_run(self.config, self.run_id):
                if item["type"] == "tool" and item["status"] == "running":
                    tools += 1
                self.add(item)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.add({"type": "error", "message": f"slopulus {error.code}: {detail}"})
        except (urllib.error.URLError, OSError, ValueError) as error:
            self.add({"type": "error", "message": f"slopulus unreachable: {error}"})
        settle_approvals(self)
        with self.cond:
            self.finished = True
            self.ended = time.monotonic()
            if self.state in ("running", "waiting for approval"):
                self.state = "failed"
            self.cond.notify_all()
        log.info(
            "task %s (run %s) %s after %.1fs, %d tool calls",
            self.session,
            self.run_id,
            self.state,
            self.ended - self.started,
            tools,
        )
        self.post_result()

    def add(self, item):
        # Anything after an approval request means Hermes moved on (answered,
        # or its own timeout).
        settle_approvals(self)
        if item["type"] == "approval":
            item["code"] = open_approval(self, item)
        with self.cond:
            self.items.append(item)
            self.track(item)
            self.cond.notify_all()
            unheard = not self.pages or self.hung_up
        if item["type"] == "end_call":
            # Without a page the call has ended already.
            log.info("task %s ends the call%s", self.session, " (no call)" if unheard else "")
        self.ask_unheard()

    def track(self, item):
        """Keep the state the task list shows (under self.cond)."""
        kind = item["type"]
        if kind == "approval":
            self.state = "waiting for approval"
            self.progress = f"waiting for approval: {item.get('description') or item.get('command')}"
        elif kind == "tool":
            self.state = "running"
            self.progress = item.get("note") or f"{item.get('label')}: {item.get('preview')}"
        elif kind == "delta":
            self.result += item.get("text") or ""
        elif kind == "done":
            self.state = {"stop": "done", "cancelled": "stopped"}.get(item["finish_reason"], "failed")
            if item.get("error") and not self.result:
                self.result = item["error"]
        elif kind == "error":
            self.state = "failed"
            self.result = self.result or item["message"]

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

    def set_thread(self, thread_id):
        with self.cond:
            self.thread_id = thread_id

    def ask_unheard(self):
        """Send a pending approval to Matrix once no call can answer it."""
        with self.cond:
            if self.pages and not self.hung_up:
                return
        with APPROVALS_LOCK:
            unasked = [
                (code, item)
                for code, (task, item) in APPROVALS.items()
                if task is self and not item.get("asked")
            ]
            for _, item in unasked:
                item["asked"] = True
        for code, item in unasked:
            ask_matrix(self, code, item)

    def post_matrix(self, text):
        """Post into the task's Matrix thread (the top level of the task room
        while the gateway has not reported the thread yet); False without a
        task route or when posting failed."""
        if not self.config.task_webhook:
            return False
        try:
            notify_matrix(
                self.config, text, self.config.task_webhook, {"thread_id": self.thread_id or ""}
            )
            return True
        except (urllib.error.URLError, OSError) as error:
            log.warning("posting to the thread of task %s failed: %s", self.session, error)
            return False

    def post_result(self):
        if self.state == "done":
            text = self.result.strip() or "slopulus finished without an answer."
        elif self.state == "stopped":
            text = "⏹️ Stopped."
        else:
            text = f"❌ This request failed: {self.result.strip() or self.state}"
        self.post_matrix(text)


def open_approval(task, item):
    with APPROVALS_LOCK:
        code = secrets.token_hex(2)
        while code in APPROVALS:
            code = secrets.token_hex(2)
        APPROVALS[code] = (task, item)
    return code


def settle_approvals(task):
    with APPROVALS_LOCK:
        for code in [code for code, (owner, _) in APPROVALS.items() if owner is task]:
            del APPROVALS[code]


def ask_matrix(task, code, item):
    """Ask an approval in the task's Matrix thread, without a task route in
    the owner's DM."""
    text = (
        f'slopulus needs your approval for "{task.title}" from a voice call: '
        + (item.get("description") or "run a command")
    )
    if item.get("command"):
        text += f"\n```\n{item['command']}\n```"
    text += f"\nAnswer with `/assist approve {code}` or `/assist deny {code}`."
    if item.get("timeout_s"):
        text += f" Unanswered, it is denied after {round(item['timeout_s'] / 60)} minutes."
    if task.post_matrix(text):
        log.info("approval %s asked in the thread of task %s", code, task.session)
        return
    if not task.config.matrix_webhook:
        log.info("approval %s has no listener and no Matrix webhook", code)
        return
    try:
        notify_matrix(task.config, text)
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
    server_version = "slopulus-voice"
    config: Config
    static: Path
    access_token: "str | None" = None
    app_token: "str | None" = None

    def authorized(self, also_hermes_key=False):
        """Check the page's bearer token (or, where allowed, the API server key
        the slopulus-voice plugin in the gateway holds); answer 401 when it is
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
        if urllib.parse.urlsplit(self.path).path == "/tasks":
            # The page, or the slopulus-voice plugin's voice_tasks tool.
            if self.authorized(also_hermes_key=True):
                self.handle_tasks()
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
        # /approve, /tasks/stop and /tasks/thread also serve the slopulus-voice
        # plugin in the gateway.
        plugin_routes = ("/approve", "/tasks/stop", "/tasks/thread")
        if not self.authorized(also_hermes_key=self.path in plugin_routes):
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
        elif self.path == "/tasks/stop":
            self.handle_task_stop(request)
        elif self.path == "/tasks/thread":
            self.handle_task_thread(request)
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
        # The clients' `replace` only says that another delegation was still
        # running, not that this one corrects it: every delegation is a task of
        # its own, and the task that hears a correction stops the task it
        # corrects itself (voice_task_stop, from the task list it is given).
        try:
            task = start_task(self.config, hermes_session, lines)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"slopulus {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"slopulus unreachable: {error}"})
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        task.attach()
        try:
            sent = 0
            while True:
                with task.cond:
                    if sent == len(task.items) and not task.finished:
                        task.cond.wait(PAGE_KEEPALIVE_SECONDS)
                    new = task.items[sent:]
                    sent += len(new)
                    done = task.finished and sent == len(task.items)
                for item in new:
                    self.write_line(item)
                if done:
                    break
                if not new:
                    self.wfile.write(b"\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Only the page is gone: this server keeps following the task.
            log.info("page left task %s", task.session)
        finally:
            task.detach()

    def handle_hangup(self, request):
        """The call ended. No page hears this conversation's tasks any more,
        and what the user said since the last delegation becomes a task."""
        hermes_session = request.get("hermes_session")
        lines = request.get("lines") or []
        if (
            not isinstance(hermes_session, str)
            or not SESSION_ID_RE.match(hermes_session)
            or not isinstance(lines, list)
        ):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid hang-up"})
            return
        call = get_call(hermes_session)
        with CALLS_LOCK:
            tasks = list(call.tasks.values())
        for task in tasks:
            task.hang_up()
        self.post_call_transcript(hermes_session, request.get("call"), tasks)
        if not any(line.get("speaker") == "user" for line in lines):
            self.send_json(HTTPStatus.OK, {"run_id": None})
            return
        try:
            task = start_task(self.config, hermes_session, lines, hung_up=True)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"slopulus {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"slopulus unreachable: {error}"})
            return
        log.info("hang-up of %s left a request: task %s", hermes_session, task.session)
        self.send_json(HTTPStatus.OK, {"run_id": task.run_id, "task": task.id})

    def post_call_transcript(self, hermes_session, lines, tasks):
        """The whole call, both sides, and its tasks as one Matrix message
        (transcript route)."""
        if not self.config.transcript_webhook or not isinstance(lines, list):
            return
        spoken = render_lines(line for line in lines if isinstance(line, dict))
        if not spoken:
            return
        title = "📞 Voice call, ended " + time.strftime("%a %d %b %Y %H:%M")
        text = f"{title}\n\n{spoken}"
        if tasks:
            text += "\n\nTasks (each has its own thread):\n" + "\n".join(
                f"{task.id}: {task.title} ({task.state})" for task in tasks
            )
        try:
            notify_matrix(self.config, text, self.config.transcript_webhook)
        except (urllib.error.URLError, OSError) as error:
            log.warning("call transcript of %s not posted: %s", hermes_session, error)

    def handle_tasks(self):
        """GET /tasks?call=<hermes session>: the call's tasks, oldest first."""
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        session = (query.get("call") or [""])[0]
        with CALLS_LOCK:
            call = CALLS.get(session)
            tasks = list(call.tasks.values()) if call else []
        self.send_json(HTTPStatus.OK, {"call": session, "tasks": [task.info() for task in tasks]})

    def handle_task_stop(self, request):
        """POST /tasks/stop {call, task}: stop one running task of a call."""
        with CALLS_LOCK:
            call = CALLS.get(request.get("call"))
            task = call.tasks.get(request.get("task")) if call else None
        if task is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": f"no task {request.get('task')}"})
            return
        if task.finished:
            self.send_json(HTTPStatus.CONFLICT, {"error": f"task {task.id} is {task.state} already"})
            return
        stop_run(self.config, task.run_id)
        self.send_json(HTTPStatus.OK, {"task": task.id, "title": task.title, "state": "stopping"})

    def handle_task_thread(self, request):
        """POST /tasks/thread {session, thread_id}: the gateway opened the
        task's Matrix thread; results and approvals go there."""
        task = find_task(request.get("session"))
        thread_id = request.get("thread_id")
        if task is None or not isinstance(thread_id, str) or not thread_id:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "no such task"})
            return
        task.set_thread(thread_id)
        log.info("task %s has Matrix thread %s", task.session, thread_id)
        self.send_json(HTTPStatus.OK, {"task": task.id})

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
        task, item = pending
        try:
            result = hermes_approve(self.config, task.run_id, item, choice)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"slopulus {error.code}: {detail}"})
            return
        except (urllib.error.URLError, OSError, ValueError) as error:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": f"slopulus unreachable: {error}"})
            return
        with APPROVALS_LOCK:
            APPROVALS.pop(code, None)
        if result.get("status") == "already_resolved":
            self.send_json(HTTPStatus.CONFLICT, {"error": f"approval {code} was already answered"})
            return
        log.info("approval %s (task %s): %s %s", code, task.session, choice, result.get("status"))
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
        "receives approvals no call can answer (and the call transcripts without --transcript-webhook)",
    )
    parser.add_argument(
        "--transcript-webhook",
        help="webhook route like --matrix-webhook that receives the transcript of every call",
    )
    parser.add_argument(
        "--task-webhook",
        help="webhook route like --matrix-webhook whose payload's thread_id picks the Matrix thread: "
        "receives the result and the approvals of every task in that task's thread",
    )
    parser.add_argument("--config", help="JSON file: voice, model, idle_seconds, glossary, instructions")
    parser.add_argument(
        "--static",
        default=os.environ.get("SLOPULUS_VOICE_STATIC"),
        help="directory with index.html, app.js, style.css (default: $SLOPULUS_VOICE_STATIC)",
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
        transcript_webhook=args.transcript_webhook,
        task_webhook=args.task_webhook,
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
