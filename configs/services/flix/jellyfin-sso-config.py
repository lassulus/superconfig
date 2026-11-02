"""Write the declared settings into Jellyfin's SSO plugin and branding XML.

Jellyfin and the plugin rewrite both files at runtime (account links, UI
edits), so only the declared elements are replaced and the rest is kept.
"""
import json
import os
import sys
import xml.etree.ElementTree as ET


def load(path, root_tag):
    if os.path.exists(path):
        return ET.parse(path)
    return ET.ElementTree(ET.Element(root_tag))


def child(parent, tag):
    node = parent.find(tag)
    if node is None:
        node = ET.SubElement(parent, tag)
    return node


def set_values(parent, values):
    for tag, value in values.items():
        node = child(parent, tag)
        node.clear()
        if isinstance(value, bool):
            node.text = "true" if value else "false"
        elif isinstance(value, list):
            for item in value:
                ET.SubElement(node, "string").text = item
        else:
            node.text = value


def save(tree, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ET.indent(tree)
    tmp = path + ".tmp"
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    os.replace(tmp, path)


with open(sys.argv[1]) as f:
    cfg = json.load(f)

try:
    with open(cfg["clientIdFile"]) as f:
        client_id = f.read().strip()
except FileNotFoundError:
    client_id = ""
if not client_id:
    print(f"{cfg['clientIdFile']} is missing, disabling {cfg['provider']}")

plugin = load(cfg["pluginConfig"], "PluginConfiguration")
oid_configs = child(plugin.getroot(), "OidConfigs")
for item in oid_configs.findall("item"):
    if item.findtext("key/string") == cfg["provider"]:
        break
else:
    item = ET.SubElement(oid_configs, "item")
    ET.SubElement(ET.SubElement(item, "key"), "string").text = cfg["provider"]
provider = child(child(item, "value"), "PluginConfiguration")
set_values(
    provider,
    cfg["oid"] | {"OidClientId": client_id, "Enabled": client_id != ""},
)
save(plugin, cfg["pluginConfig"])

branding = load(cfg["brandingConfig"], "BrandingOptions")
set_values(
    branding.getroot(),
    {"LoginDisclaimer": cfg["loginDisclaimer"] if client_id else ""},
)
save(branding, cfg["brandingConfig"])
