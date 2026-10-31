"""hermes-voice's side inside the Hermes gateway (tools/hermes-voice).

matrix_dm_send lets every session, the voice calls on the API server included,
write to the owner's Matrix DM (the gateway's Matrix home room). Hermes
registers its send_message tool for no session (tools/send_message_tool.py
keeps it out of the model's tools on purpose); this one reaches that single
room, through the gateway's live Matrix adapter. Sent messages are mirrored into the DM's session, so the
Matrix side sees what was asked when the user answers there.

end_call ends the voice call the session belongs to. The tool itself only
checks that it runs in a voice session and says so; hermes-voice sees the
call in the run's event stream and lets the page close the call once the
current reply has been spoken.

/assist approve|deny [code] answers an approval that hermes-voice asked in the
DM because no call could hear it. The gateway only dispatches commands of
allowed users (MATRIX_ALLOWED_USERS), so the answer is the user's own; the
agent cannot issue it. The code may be left out while exactly one approval
waits.

Every voice call gets its own thread in the Matrix home room, holding the
call's transcript: after each turn of a voice session (post_llm_call), the
spoken conversation the turn was delegated with (both sides, small talk
included) and Hermes' answer go into that call's thread. The thread root is
posted on the call's first turn; the webhook route cannot thread, since it
does not return the root's event id.
"""

import asyncio
import json
import logging
import os
import time
import urllib.error
import urllib.request

log = logging.getLogger(__name__)

SEND_SCHEMA = {
    "name": "matrix_dm_send",
    "description": (
        "Send a message to the user's Matrix chat with you (their DM with the Hermes bot). Use "
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

# hermes-voice names the Hermes session of a call voice-<date>-<random>.
VOICE_SESSION_PREFIX = "voice-"

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
    None when it is no hermes-voice call."""
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
    """Whether the calling session is a hermes-voice call: an API server
    session whose lineage starts at a voice-* session."""
    from gateway.session_context import get_session_env

    if get_session_env("HERMES_SESSION_PLATFORM", "") != "api_server":
        return False
    return voice_call_id(session_id or get_session_env("HERMES_SESSION_ID", "")) is not None


def end_call(args, session_id=None, **_kw):
    from tools.registry import tool_error

    if not voice_session(session_id):
        return tool_error("end_call only works in a voice call; there is no call to end here.")
    return json.dumps({"status": "The call ends once your reply has been spoken."})


# hermes-voice's delegation text (hermes_voice.transcript_message).
TRANSCRIPT_HEADER = "Spoken conversation since the last request, newest last:"
# Thread root event id per call (its voice-* session id). Only in memory: a
# call still running across a gateway restart continues in a new thread.
THREADS = {}
# Serializes the posts (thread root first), on the gateway loop.
POST_LOCK = None


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


async def post_transcript(adapter, room, call_id, text):
    global POST_LOCK
    if POST_LOCK is None:
        POST_LOCK = asyncio.Lock()
    async with POST_LOCK:
        root = THREADS.get(call_id)
        if root is None:
            root = await adapter.create_handoff_thread(
                room, "📞 Voice call, " + time.strftime("%a %d %b %Y %H:%M")
            )
            if root is None:
                log.warning("voice transcript: no thread for %s", call_id)
                return
            THREADS[call_id] = root
        result = await adapter.send(room, text, metadata={"thread_id": root})
        if not result.success:
            log.warning("voice transcript: posting for %s failed: %s", call_id, result.error)


def transcript(session_id=None, user_message=None, assistant_response=None, platform=None, **_kw):
    """post_llm_call: put a voice turn into its call's Matrix thread."""
    if getattr(platform, "value", platform) != "api_server":
        return
    call_id = voice_call_id(session_id)
    if call_id is None:
        return
    spoken = str(user_message or "").removeprefix(TRANSCRIPT_HEADER).strip()
    answer = str(assistant_response or "").strip()
    text = "\n".join(part for part in (spoken, answer and f"Hermes: {answer}") if part)
    room = os.environ.get("MATRIX_HOME_ROOM")
    runner, adapter = matrix_adapter()
    loop = getattr(runner, "_gateway_loop", None)
    if not (text and room and adapter and loop):
        return
    from agent.async_utils import safe_schedule_threadsafe

    safe_schedule_threadsafe(
        post_transcript(adapter, room, call_id, text),
        loop,
        logger=log,
        log_message="voice transcript: scheduling the post failed",
    )


def assist(raw_args):
    from agent.secret_scope import get_secret

    words = raw_args.split()
    if not words or words[0] not in CHOICES or len(words) > 2:
        return "Usage: /assist approve|deny [code]"
    answer = {"choice": CHOICES[words[0]]}
    if len(words) == 2:
        answer["code"] = words[1]
    request = urllib.request.Request(
        os.environ["HERMES_VOICE_URL"].rstrip("/") + "/approve",
        data=json.dumps(answer).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {get_secret('API_SERVER_KEY')}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        try:
            reason = json.load(error).get("error")
        except ValueError:
            reason = error.reason
        return f"hermes-voice: {reason}"
    except (urllib.error.URLError, OSError) as error:
        return f"hermes-voice unreachable: {error}"
    what = result.get("description") or "the command"
    if answer["choice"] == "deny":
        return f"Denied: {what}."
    return f"Approved: {what}. Hermes continues."


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
    ctx.register_hook("post_llm_call", transcript)
    ctx.register_command(
        "assist",
        handler=assist,
        description="Answer an approval from a voice call (assist.lassul.us)",
        args_hint="approve|deny [code]",
    )
