# Audio routing matrix: one Home Assistant switch (MQTT discovery) per
# source and speaker. While a switch is on, the source's PipeWire node is
# linked to the speaker's node. Sources are the fixed nodes from the config
# plus every connected Bluetooth A2DP source (bluez_input.*; phones left on
# the "off" profile are switched to A2DP). A new source starts on the
# config's `rooms` of it, else on all speakers. Each speaker
# also gets a volume (MQTT number), applied to its node with wpctl. Usage:
# audio-matrix CONFIG.json [--dry-run], --dry-run prints the pw-link and
# wpctl calls without running them.
import json
import os
import queue
import subprocess
import sys
import threading

import paho.mqtt.client as mqtt

with open(sys.argv[1]) as f:
    config = json.load(f)
dry_run = "--dry-run" in sys.argv[2:]
speakers = config["speakers"]

events = queue.Queue()

# PipeWire objects by id: devices, nodes, ports and links
graph = {}
interesting = {
    "PipeWire:Interface:Device",
    "PipeWire:Interface:Node",
    "PipeWire:Interface:Port",
    "PipeWire:Interface:Link",
}


def read_graph(proc):
    # every update is a JSON array whose closing bracket starts a line
    chunk = []
    try:
        for line in proc.stdout:
            chunk.append(line)
            if line.startswith("]"):
                events.put(("graph", json.loads("".join(chunk))))
                chunk = []
    finally:
        proc.kill()
        events.put(("exit", proc.wait()))


def apply(update):
    for o in update:
        if "type" not in o:
            graph.pop(o["id"], None)
        elif o["type"] in interesting:
            graph[o["id"]] = o


def objects(kind):
    for o in graph.values():
        if o["type"] == "PipeWire:Interface:" + kind:
            yield o["id"], o["info"]


def nodes_named(name):
    return [
        i for i, info in objects("Node")
        if info["props"].get("node.name") == name
    ]


def sources():
    found = {
        key: {
            "label": s["label"],
            "kind": key,
            "nodes": nodes_named(s["node"]),
            "rooms": s.get("rooms"),
        }
        for key, s in config["sources"].items()
    }
    for i, info in objects("Node"):
        props = info["props"]
        address = props.get("api.bluez5.address")
        if not props.get("node.name", "").startswith("bluez_input.") or not address:
            continue
        key = address.lower().replace(":", "_")
        src = found.setdefault(
            key,
            {
                "label": props.get("node.description", address),
                "kind": "bluetooth",
                "nodes": [],
            },
        )
        src["nodes"].append(i)
    return found


# bluez devices whose profile was switched on, so a phone that turns it off
# again is left alone
profiled = set()


# WirePlumber leaves a newly paired phone on the "off" profile when its A2DP
# transport is not up yet at connect time, so it gets no bluez_input node.
# Switch such devices to the A2DP (audio-gateway) profile once.
def bluetooth_profiles():
    for i, info in objects("Device"):
        if info["props"].get("device.api") != "bluez5" or i in profiled:
            continue
        params = info.get("params", {})
        current = (params.get("Profile") or [{}])[0].get("name")
        gateway = [
            p for p in params.get("EnumProfile", [])
            if p.get("name") == "audio-gateway" and p.get("available") != "no"
        ]
        if current == "off" and gateway:
            run("wpctl", "set-profile", i, gateway[0]["index"])
            profiled.add(i)


# whether both nodes have their ports to link yet
def ports(out_node, in_node):
    have = {
        (int(info["props"]["node.id"]), info["direction"])
        for _, info in objects("Port")
    }
    return (out_node, "output") in have and (in_node, "input") in have


def linked(out_node, in_node):
    return any(
        info["output-node-id"] == out_node and info["input-node-id"] == in_node
        for _, info in objects("Link")
    )


def run(*cmd):
    print(" ".join(map(str, cmd)), flush=True)
    if not dry_run:
        subprocess.run(list(map(str, cmd)))


def pw_link(*args):
    run("pw-link", *args)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def store(path, data):
    with open(path + ".tmp", "w") as f:
        json.dump(data, f)
    os.replace(path + ".tmp", path)


# speakers each source plays on, by source key
routes = load(config["state"])
# volume in percent by speaker, 100 if never set
volumes = load(config["volumes"])
# volume last set on each speaker node, by node id
applied = {}


def save():
    store(config["state"], routes)


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
client.username_pw_set(config["mqtt"]["user"], config["mqtt"]["password"])


def entity(key, speaker):
    return f"audio_route_{key}_{speaker}"


def topic(key, speaker):
    return f"gg23/audio-route/{key}/{speaker}"


def publish_state(key, speaker):
    state = "ON" if speaker in routes[key] else "OFF"
    client.publish(topic(key, speaker) + "/state", state, retain=True)


def volume_topic(speaker):
    return f"gg23/audio-volume/{speaker}"


def publish_volumes():
    for speaker, sp in speakers.items():
        base = volume_topic(speaker)
        client.publish(base + "/state", volumes.get(speaker, 100), retain=True)
        discovery = {
            "name": sp["label"],
            "unique_id": f"acheron_audio_volume_{speaker}",
            "default_entity_id": f"number.audio_volume_{speaker}",
            "command_topic": base + "/set",
            "state_topic": base + "/state",
            "min": 0,
            "max": 100,
            "step": 1,
            "mode": "slider",
            "unit_of_measurement": "%",
            "icon": "mdi:volume-high",
            "device": {
                "identifiers": ["acheron_audio_volume"],
                "name": "Room volume",
            },
        }
        client.publish(
            f"homeassistant/number/audio_volume_{speaker}/config",
            json.dumps(discovery),
            retain=True,
        )


def publish(key, src):
    for speaker, sp in speakers.items():
        base = topic(key, speaker)
        attributes = {
            "source": src["label"],
            "speaker": sp["label"],
            "kind": src["kind"],
        }
        client.publish(base + "/attributes", json.dumps(attributes), retain=True)
        publish_state(key, speaker)
        discovery = {
            "name": sp["label"],
            "unique_id": "acheron_" + entity(key, speaker),
            "default_entity_id": "switch." + entity(key, speaker),
            "command_topic": base + "/set",
            "state_topic": base + "/state",
            "json_attributes_topic": base + "/attributes",
            "icon": "mdi:speaker",
            "device": {
                "identifiers": ["acheron_audio_" + key],
                "name": src["label"],
            },
        }
        client.publish(
            f"homeassistant/switch/{entity(key, speaker)}/config",
            json.dumps(discovery),
            retain=True,
        )


def unpublish(key):
    for speaker in speakers:
        client.publish(
            f"homeassistant/switch/{entity(key, speaker)}/config", "", retain=True
        )
        for t in ["state", "attributes"]:
            client.publish(topic(key, speaker) + "/" + t, "", retain=True)


# label of each source whose switches are published, None if unknown
published = {}


def sync():
    bluetooth_profiles()
    found = sources()
    for key in [k for k in published if k not in found]:
        unpublish(key)
        del published[key]
    for key, src in found.items():
        if key not in routes:
            rooms = src.get("rooms")
            routes[key] = list(speakers if rooms is None else rooms)
            save()
        if key not in published or published[key] != src["label"]:
            publish(key, src)
            published[key] = src["label"]
        for speaker, sp in speakers.items():
            want = speaker in routes[key]
            for out_node in src["nodes"]:
                for in_node in nodes_named(sp["node"]):
                    if linked(out_node, in_node):
                        if not want:
                            pw_link("-d", out_node, in_node)
                    elif want and ports(out_node, in_node):
                        pw_link(out_node, in_node)
    for speaker, sp in speakers.items():
        volume = volumes.get(speaker, 100)
        for node in nodes_named(sp["node"]):
            if applied.get(node) != volume:
                run("wpctl", "set-volume", node, volume / 100)
                applied[node] = volume


def command(t, payload):
    _, _, key, speaker, _ = t.split("/")
    if key not in published or speaker not in speakers:
        return
    if payload == "ON" and speaker not in routes[key]:
        routes[key].append(speaker)
    elif payload == "OFF" and speaker in routes[key]:
        routes[key].remove(speaker)
    save()
    publish_state(key, speaker)


def volume_command(t, payload):
    speaker = t.split("/")[2]
    if speaker not in speakers:
        return
    try:
        volumes[speaker] = max(0, min(100, round(float(payload))))
    except ValueError:
        return
    store(config["volumes"], volumes)
    client.publish(volume_topic(speaker) + "/state", volumes[speaker], retain=True)


def on_connect(client, userdata, flags, reason_code, properties):
    client.subscribe("gg23/audio-route/+/+/set")
    client.subscribe("gg23/audio-volume/+/set")
    events.put(("connect",))


def on_message(client, userdata, msg):
    events.put(("command", msg.topic, msg.payload.decode()))


client.on_connect = on_connect
client.on_message = on_message
client.connect_async(config["mqtt"]["host"])
client.loop_start()
pw_dump = subprocess.Popen(
    ["pw-dump", "--monitor", "--no-colors"],
    stdout=subprocess.PIPE,
    text=True,
)
threading.Thread(target=read_graph, args=(pw_dump,), daemon=True).start()

graph_ready = False


def handle(event):
    global graph_ready, published
    if event[0] == "graph":
        apply(event[1])
        graph_ready = True
    elif event[0] == "connect":
        # republish everything, and clear the switches of sources that
        # vanished while nobody was connected
        published = dict.fromkeys(routes)
        publish_volumes()
    elif event[0] == "command":
        if event[1].startswith("gg23/audio-volume/"):
            volume_command(*event[1:])
        else:
            command(*event[1:])
    elif event[0] == "exit":
        sys.exit(f"pw-dump exited with {event[1]}")


while True:
    handle(events.get())
    # sync once per burst, so links just created are seen before it
    while not events.empty():
        handle(events.get())
    if graph_ready:
        sync()
