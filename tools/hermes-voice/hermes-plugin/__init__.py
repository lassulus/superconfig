"""hermes-voice's side inside the Hermes gateway (tools/hermes-voice).

matrix_dm_send lets every session, the voice calls on the API server included,
write to the owner's Matrix DM (the gateway's Matrix home room). Hermes
registers its send_message tool for no session (tools/send_message_tool.py
keeps it out of the model's tools on purpose); this one reaches that single
room and uses the same sender as cron delivery, through the gateway's live
Matrix adapter. Sent messages are mirrored into the DM's session, so the
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
"""

import json
import os
import urllib.error
import urllib.request

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
    from tools.send_message_tool import send_message_tool

    return send_message_tool(
        {"action": "send", "target": "matrix", "message": args.get("message", "")}
    )


def voice_session(session_id):
    """Whether the calling session is a hermes-voice call: an API server
    session whose lineage starts at a voice-* session (context compression
    continues a session under a new id, with the old one as parent)."""
    from gateway.session_context import get_session_env
    from hermes_state import SessionDB

    if get_session_env("HERMES_SESSION_PLATFORM", "") != "api_server":
        return False
    session_id = session_id or get_session_env("HERMES_SESSION_ID", "")
    db = SessionDB(read_only=True)
    try:
        seen = set()
        while session_id and session_id not in seen and len(seen) < 100:
            if session_id.startswith(VOICE_SESSION_PREFIX):
                return True
            seen.add(session_id)
            session = db.get_session(session_id)
            session_id = session and session.get("parent_session_id")
    finally:
        db.close()
    return False


def end_call(args, session_id=None, **_kw):
    from tools.registry import tool_error

    if not voice_session(session_id):
        return tool_error("end_call only works in a voice call; there is no call to end here.")
    return json.dumps({"status": "The call ends once your reply has been spoken."})


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
    ctx.register_command(
        "assist",
        handler=assist,
        description="Answer an approval from a voice call (assist.lassul.us)",
        args_hint="approve|deny [code]",
    )
