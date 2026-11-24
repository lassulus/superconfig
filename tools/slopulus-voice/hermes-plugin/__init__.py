"""slopulus-voice's side inside the Hermes gateway (tools/slopulus-voice).

matrix_dm_send lets every session, the voice calls on the API server included,
write to the owner's Matrix DM (the gateway's Matrix home room). Hermes
registers its send_message tool for no session (tools/send_message_tool.py
keeps it out of the model's tools on purpose); this one reaches that single
room, through the gateway's live Matrix adapter. Sent messages are mirrored into the DM's session, so the
Matrix side sees what was asked when the user answers there.

end_call ends the voice call the session belongs to. The tool itself only
checks that it runs in a voice session and says so; slopulus-voice sees the
call in the run's event stream and lets the page close the call once the
current reply has been spoken.

Every request of a voice call runs as a task in its own Hermes session,
`<call session>-t<n>`, a fork of the call session (slopulus_voice.py,
start_task). When a task's run starts, the task gets its own Matrix thread:
the request is posted as a thread root in the room for voice calls
($SLOPULUS_VOICE_TASK_ROOM), and the thread's route is pointed at the task
session the way Hermes's own /handoff does it (create_handoff_thread, then
the runner's _handoff_repoint), so a reply in that thread continues the task
with its full context, during and after the call. slopulus-voice learns the
thread (POST /tasks/thread) and posts the result and approvals there. When a
task's API turn ends, its request and answer are appended to the call
session, so the next task, a fork of it, knows them.

voice_tasks lists the tasks of the call a session belongs to, voice_task_stop
stops one (slopulus-voice's /tasks routes): the task that hears a correction
stops the task it corrects, and the user can ask what runs or stop one, by
voice or in a task's thread.

/assist approve|deny [code] answers an approval that slopulus-voice asked in
Matrix because no call could hear it. The gateway only dispatches commands of
allowed users (MATRIX_ALLOWED_USERS), so the answer is the user's own; the
agent cannot issue it. The code may be left out while exactly one approval
waits.
"""

import asyncio
import json
import logging
import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request

log = logging.getLogger(__name__)

SEND_SCHEMA = {
    "name": "matrix_dm_send",
    "description": (
        "Send a message to the user's Matrix chat with you (their DM with the slopulus bot). Use "
        "it when the user asks you to tell or send them something there, or when you need to ask "
        "them something while no conversation with them is open: their answer arrives in that "
        "Matrix chat. To read that chat, look up the Matrix DM session with session_search "
        "(chat_history_lookup) and read its messages."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "message": {"type": "string", "description": "The message, Markdown allowed."},
        },
        "required": ["message"],
    },
}

END_CALL_SCHEMA = {
    "name": "end_call",
    "description": (
        "End the current voice call after the current reply has been spoken. Only works in a "
        "voice call (assist.lassul.us). Call it when the user says goodbye, says that is all, "
        "asks you to hang up or says they are leaving, once any work they asked for has been "
        "started or handed off; never while you still need an answer from them, such as an "
        "approval. Your reply is still spoken before the call ends: keep it to a short "
        "confirmation or goodbye."
    ),
    "parameters": {"type": "object", "properties": {}},
}

TASKS_SCHEMA = {
    "name": "voice_tasks",
    "description": (
        "List the requests (tasks) of the current voice call: each runs in its own session at the "
        "same time. Shows each task's id, title, state (running, waiting for approval, done, "
        "stopped, failed), its current step or its result. Only works in a voice call's task."
    ),
    "parameters": {"type": "object", "properties": {}},
}

STOP_SCHEMA = {
    "name": "voice_task_stop",
    "description": (
        "Stop one running task of the current voice call, by its id (t1, t2, ... from the task "
        "list): one the user corrected, changed or cancelled. Stop only the task the user meant, "
        "never another one."
    ),
    "parameters": {
        "type": "object",
        "properties": {"task": {"type": "string", "description": "The task id, such as t2."}},
        "required": ["task"],
    },
}

# slopulus-voice names the Hermes session of a call voice-<date>-<random>, and
# the session of each of its tasks <call session>-t<n>.
VOICE_SESSION_PREFIX = "voice-"
TASK_SESSION_RE = re.compile(r"^(voice-[A-Za-z0-9_-]+)-(t[0-9]+)$")
# The room the task threads go to (slopulus-voice.nix).
TASK_ROOM_ENV = "SLOPULUS_VOICE_TASK_ROOM"
# slopulus-voice's request header, left out of the thread root.
TRANSCRIPT_HEADER = "Spoken conversation since the last request, newest last:"

# Task sessions whose thread this gateway opened.
_threaded = set()
_threaded_lock = threading.Lock()

CHOICES = {"approve": "once", "deny": "deny"}


def send(args, **_kw):
    """Send through the live Matrix adapter on the gateway's loop.

    Not send_message_tool: its Matrix route awaits adapter.send() on the
    tool's own loop (tools/send_message_senders.py), where aiohttp fails
    with "Timeout context manager should be used inside a task", and
    without a live adapter it connects a second client on the gateway's
    crypto store, which breaks E2EE."""
    from gateway.mirror import mirror_to_session
    from tools.registry import tool_error

    message = args.get("message", "")
    room = os.environ.get("MATRIX_HOME_ROOM")
    runner, adapter = matrix_adapter()
    loop = getattr(runner, "_gateway_loop", None)
    if not (room and adapter and loop and loop.is_running()):
        return tool_error("The gateway's Matrix connection is not available.")
    result = asyncio.run_coroutine_threadsafe(adapter.send(room, message), loop).result()
    if not result.success:
        return tool_error(f"Matrix send failed: {result.error}")
    mirror_to_session("matrix", room, message)
    return json.dumps({"success": True, "message_id": result.message_id})


def voice_call_id(session_id):
    """The voice-* session a session's lineage starts at (context compression
    continues a session under a new id, with the old one as parent), or
    None when it is no slopulus-voice call."""
    from hermes_state import SessionDB

    db = SessionDB(read_only=True)
    try:
        seen = set()
        while session_id and session_id not in seen and len(seen) < 100:
            if session_id.startswith(VOICE_SESSION_PREFIX):
                return session_id
            seen.add(session_id)
            session = db.get_session(session_id)
            session_id = session and session.get("parent_session_id")
    finally:
        db.close()
    return None


def voice_session(session_id):
    """Whether the calling session is a slopulus-voice call: an API server
    session whose lineage starts at a voice-* session."""
    from gateway.session_context import get_session_env

    if get_session_env("HERMES_SESSION_PLATFORM", "") != "api_server":
        return False
    return voice_call_id(session_id or get_session_env("HERMES_SESSION_ID", "")) is not None


def voice_task(session_id):
    """(call session, task id) of a slopulus-voice task session, else None."""
    match = TASK_SESSION_RE.match(session_id or "")
    return match.groups() if match else None


def current_session(session_id):
    from gateway.session_context import get_session_env

    return session_id or get_session_env("HERMES_SESSION_ID", "")


def voice_api(method, path, payload=None):
    """Call slopulus-voice with the API server key; the parsed JSON answer.
    Raises urllib.error.HTTPError and URLError/OSError."""
    from agent.secret_scope import get_secret

    request = urllib.request.Request(
        os.environ["SLOPULUS_VOICE_URL"].rstrip("/") + path,
        data=None if payload is None else json.dumps(payload).encode(),
        method=method,
        headers={
            "Authorization": f"Bearer {get_secret('API_SERVER_KEY')}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def voice_api_error(error):
    """slopulus-voice's error message of a failed voice_api call."""
    if isinstance(error, urllib.error.HTTPError):
        try:
            return f"slopulus-voice: {json.load(error).get('error')}"
        except ValueError:
            return f"slopulus-voice: {error.reason}"
    return f"slopulus-voice unreachable: {error}"


def tasks(args, session_id=None, **_kw):
    from tools.registry import tool_error

    task = voice_task(current_session(session_id))
    if task is None:
        return tool_error("voice_tasks only works in a voice call's task.")
    try:
        result = voice_api("GET", "/tasks?" + urllib.parse.urlencode({"call": task[0]}))
    except (urllib.error.URLError, OSError) as error:
        return tool_error(voice_api_error(error))
    return json.dumps({"you_are": task[1], **result})


def stop_task(args, session_id=None, **_kw):
    from tools.registry import tool_error

    task = voice_task(current_session(session_id))
    if task is None:
        return tool_error("voice_task_stop only works in a voice call's task.")
    target = str(args.get("task", "")).strip()
    if target == task[1]:
        return tool_error("That is this task itself; just stop working on it.")
    try:
        result = voice_api("POST", "/tasks/stop", {"call": task[0], "task": target})
    except (urllib.error.URLError, OSError) as error:
        return tool_error(voice_api_error(error))
    return json.dumps(result)


def open_task_thread(session_id=None, user_message=None, platform="", **_kw):
    """pre_llm_call: a task's API run starts, so the task gets its Matrix
    thread (once). Only schedules the work on the gateway's loop: a hook must
    not wait for that loop."""
    room = os.environ.get(TASK_ROOM_ENV)
    if platform != "api_server" or not room or voice_task(session_id) is None:
        return None
    with _threaded_lock:
        if session_id in _threaded:
            return None
        _threaded.add(session_id)
    runner, adapter = matrix_adapter()
    loop = getattr(runner, "_gateway_loop", None)
    if not (adapter and loop and loop.is_running()):
        log.warning("no Matrix thread for voice task %s: no live Matrix adapter", session_id)
        return None
    text = str(user_message or "").removeprefix(TRANSCRIPT_HEADER).strip()
    root = f"🎙️ Voice call request {voice_task(session_id)[1]}:\n\n{text}"
    asyncio.run_coroutine_threadsafe(bind_thread(runner, adapter, room, root, session_id), loop)
    return None


async def bind_thread(runner, adapter, room, text, session_id):
    """Post `text` as a thread root in `room`, point the thread's route at
    `session_id` like Hermes's /handoff (gateway/run_startup.py
    _handoff_resolve_destination and _handoff_repoint, without its synthetic
    turn) and tell slopulus-voice."""
    from types import SimpleNamespace

    from gateway.config import Platform
    from gateway.session import SessionSource

    try:
        root = await adapter.create_handoff_thread(room, text)
        if not root:
            log.warning("no Matrix thread for voice task %s: posting the root failed", session_id)
            return
        chat_type = await runner._handoff_home_chat_type(adapter, room, Platform.MATRIX)
        source = SessionSource(
            platform=Platform.MATRIX,
            chat_id=room,
            chat_type=chat_type,
            user_id="system:handoff",
            user_name="Handoff",
            thread_id=root,
        )
        runner._canonicalize(source)
        dest = SimpleNamespace(source=source, platform=Platform.MATRIX, handoff_config=runner.config)
        await runner._handoff_repoint(dest, runner._handoff_session_key(dest, None), session_id)
        await asyncio.to_thread(voice_api, "POST", "/tasks/thread", {"session": session_id, "thread_id": root})
        log.info("voice task %s has Matrix thread %s", session_id, root)
    except Exception:
        log.warning("Matrix thread of voice task %s failed", session_id, exc_info=True)


def record_task(session_id=None, user_message=None, assistant_response=None, platform="", **_kw):
    """post_llm_call: append a task's request and answer to its call session,
    which the call's next tasks fork."""
    task = voice_task(session_id)
    if platform != "api_server" or task is None:
        return
    from gateway.mirror import mirror_to_session

    text = str(user_message or "").removeprefix(TRANSCRIPT_HEADER).strip()
    mirror_to_session(
        "api_server",
        task[0],
        f"[Voice call task {task[1]}, session {session_id}]\n{text}\n\n"
        f"slopulus answered:\n{assistant_response or ''}",
        source_label="slopulus-voice",
        role="user",
        session_id=task[0],
    )


def end_call(args, session_id=None, **_kw):
    from tools.registry import tool_error

    if not voice_session(session_id):
        return tool_error("end_call only works in a voice call; there is no call to end here.")
    return json.dumps({"status": "The call ends once your reply has been spoken."})


def matrix_adapter():
    """The gateway runner and its live Matrix adapter (None when missing)."""
    from gateway.run import _gateway_runner_ref

    runner = _gateway_runner_ref()
    if runner is None:
        return None, None
    for platform, adapter in runner.adapters.items():
        if getattr(platform, "value", platform) == "matrix":
            return runner, adapter
    return runner, None


def assist(raw_args):
    words = raw_args.split()
    if not words or words[0] not in CHOICES or len(words) > 2:
        return "Usage: /assist approve|deny [code]"
    answer = {"choice": CHOICES[words[0]]}
    if len(words) == 2:
        answer["code"] = words[1]
    try:
        result = voice_api("POST", "/approve", answer)
    except (urllib.error.URLError, OSError) as error:
        return voice_api_error(error)
    what = result.get("description") or "the command"
    if answer["choice"] == "deny":
        return f"Denied: {what}."
    return f"Approved: {what}. slopulus continues."


def register(ctx):
    ctx.register_tool(
        name="matrix_dm_send",
        toolset="matrix_dm",
        schema=SEND_SCHEMA,
        handler=send,
        emoji="💬",
    )
    ctx.register_tool(
        name="end_call",
        toolset="voice_call",
        schema=END_CALL_SCHEMA,
        handler=end_call,
        emoji="📴",
    )
    ctx.register_tool(
        name="voice_tasks",
        toolset="voice_call",
        schema=TASKS_SCHEMA,
        handler=tasks,
        emoji="📋",
    )
    ctx.register_tool(
        name="voice_task_stop",
        toolset="voice_call",
        schema=STOP_SCHEMA,
        handler=stop_task,
        emoji="⏹️",
    )
    ctx.register_hook("pre_llm_call", open_task_thread)
    ctx.register_hook("post_llm_call", record_task)
    ctx.register_command(
        "assist",
        handler=assist,
        description="Answer an approval from a voice call (assist.lassul.us)",
        args_hint="approve|deny [code]",
    )
