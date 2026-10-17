# Audio routing matrix: one Home Assistant switch (MQTT discovery) per
# source and speaker. While a switch is on, the source's PipeWire node is
# linked to the speaker's node. Sources are the fixed nodes from the config
# plus every connected Bluetooth A2DP source (bluez_input.*). Usage:
# audio-matrix CONFIG.json [--dry-run], --dry-run prints the pw-link calls
# without running them.
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

# PipeWire objects by id: nodes, ports and links
graph = {}
interesting = {
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
        key: {"label": s["label"], "kind": key, "nodes": nodes_named(s["node"])}
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


def pw_link(*args):
    cmd = ["pw-link", *map(str, args)]
    print(" ".join(cmd), flush=True)
    if not dry_run:
        subprocess.run(cmd)


# speakers each source plays on, by source key
try:
    with open(config["state"]) as f:
        routes = json.load(f)
except FileNotFoundError:
    routes = {}


def save():
    with open(config["state"] + ".tmp", "w") as f:
        json.dump(routes, f)
    os.replace(config["state"] + ".tmp", config["state"])


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
client.username_pw_set(config["mqtt"]["user"], config["mqtt"]["password"])


def entity(key, speaker):
    return f"audio_route_{key}_{speaker}"


def topic(key, speaker):
    return f"gg23/audio-route/{key}/{speaker}"


def publish_state(key, speaker):
    state = "ON" if speaker in routes[key] else "OFF"
    client.publish(topic(key, speaker) + "/state", state, retain=True)


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
    found = sources()
    for key in [k for k in published if k not in found]:
        unpublish(key)
        del published[key]
    for key, src in found.items():
        if key not in routes:
            routes[key] = list(speakers)
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


def on_connect(client, userdata, flags, reason_code, properties):
    client.subscribe("gg23/audio-route/+/+/set")
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
    elif event[0] == "command":
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
