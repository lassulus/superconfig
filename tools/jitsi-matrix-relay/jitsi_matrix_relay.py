"""Relay the chat of a Jitsi Meet room to a Matrix room and back.

Joins the Jitsi room as a participant over XMPP (anonymous login) and the
Matrix room as an application service user, whose events the homeserver
pushes to LISTEN_PORT. The Matrix room gets a widget (served under /widget/
on LISTEN_PORT) that shows who is in the call and joins it. Any error ends
the process, so the service manager restarts it.
"""

import asyncio
import json
import logging
import os
import uuid
from urllib.parse import quote

import aiohttp
import slixmpp
from aiohttp import web
from slixmpp.xmlstream import ET

env = os.environ
JITSI_DOMAIN = env["JITSI_DOMAIN"]
JITSI_ROOM = env["JITSI_ROOM"]
XMPP_DOMAIN = env["XMPP_DOMAIN"]
XMPP_HOST = env["XMPP_HOST"]
NICK = env["JITSI_NICK"]
HOMESERVER = env["MATRIX_HOMESERVER"]
MATRIX_ROOM = env["MATRIX_ROOM"]
MATRIX_LOCALPART = env["MATRIX_LOCALPART"]
with open(env["MATRIX_AS_TOKEN_FILE"]) as f:
    AS_TOKEN = f.read().strip()
with open(env["MATRIX_HS_TOKEN_FILE"]) as f:
    HS_TOKEN = f.read().strip()
WIDGET_URL = env["WIDGET_URL"]
with open("@widget@") as f:
    WIDGET = f.read().replace("@domain@", JITSI_DOMAIN).replace("@room@", JITSI_ROOM)

MUC = f"{JITSI_ROOM}@conference.{JITSI_DOMAIN}"
NICK_NS = "http://jabber.org/protocol/nick"
MUC_NS = "http://jabber.org/protocol/muc"


class Jitsi(slixmpp.ClientXMPP):
    def __init__(self, on_message):
        super().__init__(XMPP_DOMAIN, None)
        # local connection to Prosody, which allows it unencrypted
        self.enable_starttls = False
        self.enable_direct_tls = False
        self.enable_plaintext = True
        self.relay = on_message
        self.id = uuid.uuid4().hex[:8]
        self.names = {}
        self.changed = asyncio.get_event_loop().create_future()
        self.add_event_handler("session_start", self.start)
        self.add_event_handler("presence", self.on_presence)
        self.add_event_handler("message", self.on_message)

    async def start(self, _):
        # Like a Jitsi client: ask the focus (jicofo) to set up the room,
        # which only it may create, then join it.
        iq = self.make_iq_set(ito=f"focus.{JITSI_DOMAIN}")
        iq.append(
            ET.Element(
                "{http://jitsi.org/protocol/focus}conference",
                room=MUC,
                **{"machine-uid": uuid.uuid4().hex},
            )
        )
        await iq.send()
        presence = self.make_presence(pto=f"{MUC}/{self.id}")
        x = ET.SubElement(presence.xml, f"{{{MUC_NS}}}x")
        ET.SubElement(x, f"{{{MUC_NS}}}history", maxstanzas="0")
        ET.SubElement(presence.xml, f"{{{NICK_NS}}}nick").text = NICK
        presence.send()

    def on_presence(self, presence):
        if presence["from"].bare != MUC:
            return
        resource = presence["from"].resource
        if presence["type"] == "unavailable":
            if resource == self.id:
                # kicked, or the room was destroyed
                self.disconnect()
            self.names.pop(resource, None)
        else:
            nick = presence.xml.find(f"{{{NICK_NS}}}nick")
            self.names[resource] = nick.text if nick is not None else resource
        self.changed.set_result(None)
        self.changed = asyncio.get_event_loop().create_future()

    def participants(self):
        return sorted(
            name
            for resource, name in self.names.items()
            if resource not in (self.id, "focus")
        )

    def on_message(self, msg):
        resource = msg["from"].resource
        if msg["type"] != "groupchat" or msg["from"].bare != MUC or not msg["body"]:
            return
        if resource != self.id:
            self.relay(self.names.get(resource, resource), msg["body"])

    def say(self, text):
        self.send_message(mto=MUC, mbody=text, mtype="groupchat")


class Matrix:
    def __init__(self, session):
        self.http = session
        self.user_id = None
        self.room_id = None
        self.on_message = None

    async def call(self, method, path, body=None, allow=()):
        async with self.http.request(
            method,
            f"{HOMESERVER}/_matrix/client/v3{path}",
            json=body,
            headers={"Authorization": f"Bearer {AS_TOKEN}"},
        ) as resp:
            data = await resp.json()
            if resp.status != 200 and data.get("errcode") not in allow:
                raise RuntimeError(f"{method} {path}: {resp.status} {data}")
            return data

    async def setup(self):
        await self.call(
            "POST",
            "/register",
            {"type": "m.login.application_service", "username": MATRIX_LOCALPART},
            allow=("M_USER_IN_USE",),
        )
        self.user_id = (await self.call("GET", "/account/whoami"))["user_id"]
        self.room_id = (await self.call("POST", f"/join/{quote(MATRIX_ROOM)}", {}))[
            "room_id"
        ]
        await self.widget()

    async def widget(self):
        widget_id = f"jitsi-{JITSI_ROOM}"
        room = quote(self.room_id)
        data = await self.call(
            "PUT",
            f"/rooms/{room}/state/im.vector.modular.widgets/{widget_id}",
            {
                "type": "m.custom",
                "name": "Jitsi",
                # the client fills in $matrix_display_name
                "url": f"{WIDGET_URL}?name=$matrix_display_name",
                "creatorUserId": self.user_id,
                "data": {},
            },
            allow=("M_FORBIDDEN",),
        )
        if "errcode" in data:
            print(f"cannot add the widget, needs a higher power level: {data}")
            return
        await self.call(
            "PUT",
            f"/rooms/{room}/state/io.element.widgets.layout/",
            {
                "widgets": {
                    widget_id: {"container": "top", "index": 0, "width": 100, "height": 50}
                }
            },
        )

    async def send(self, text):
        await self.call(
            "PUT",
            f"/rooms/{quote(self.room_id)}/send/m.room.message/{uuid.uuid4().hex}",
            {"msgtype": "m.text", "body": text},
        )

    async def name(self, user_id):
        member = await self.call(
            "GET",
            f"/rooms/{quote(self.room_id)}/state/m.room.member/{quote(user_id)}",
        )
        return member.get("displayname") or user_id

    async def transaction(self, request):
        # Synapse pushes the room's events to the application service.
        if request.headers.get("Authorization") != f"Bearer {HS_TOKEN}":
            return web.json_response({"errcode": "M_FORBIDDEN"}, status=403)
        for event in (await request.json())["events"]:
            body = event.get("content", {}).get("body")
            if event["type"] != "m.room.message" or not body:
                continue
            if event["room_id"] == self.room_id and event["sender"] != self.user_id:
                self.on_message(await self.name(event["sender"]), body)
        return web.json_response({})


async def events(request, jitsi):
    # Server-sent events: the participants now and after every change.
    response = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await response.prepare(request)
    while True:
        changed = jitsi.changed
        await response.write(f"data: {json.dumps(jitsi.participants())}\n\n".encode())
        await changed


async def main():
    async with aiohttp.ClientSession() as session:
        matrix = Matrix(session)
        await matrix.setup()
        jitsi = Jitsi(
            lambda name, text: asyncio.ensure_future(matrix.send(f"{name}: {text}"))
        )
        matrix.on_message = lambda name, body: jitsi.say(f"{name}: {body}")
        app = web.Application()
        app.router.add_put("/_matrix/app/v1/transactions/{txn}", matrix.transaction)
        app.router.add_get(
            "/widget/", lambda _: web.Response(text=WIDGET, content_type="text/html")
        )
        app.router.add_get("/widget/events", lambda request: events(request, jitsi))
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", int(env["LISTEN_PORT"])).start()
        jitsi.connect(XMPP_HOST, 5222)
        await jitsi.disconnected
        raise SystemExit("disconnected from the Jitsi room")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
