---
name: hedgedoc
description: Manage HedgeDoc pads on pad.lassul.us — create, read, edit, and get info on collaborative markdown documents. Use when the user wants to work with pads, notes, or shared documents.
---

# HedgeDoc Pad Skill

Manage HedgeDoc pads on `pad.lassul.us` — create, read, and edit collaborative markdown documents.

## Instance

- **URL**: `https://pad.lassul.us`
- **Access**: Anonymous (no auth required)

## Invocation

Use `s skills.hedgedoc <command>` — this IS the pad script. Do NOT use `./pad.sh` directly.

### Read a pad
```bash
s skills.hedgedoc read <pad-id>
```

### Create a new pad
```bash
# From stdin
echo "# My Document" | s skills.hedgedoc create

# From a file
s skills.hedgedoc create /path/to/file.md
```
Returns the new pad URL.

### Edit a pad (in-place)
```bash
# From stdin
echo "# Updated content" | s skills.hedgedoc edit <pad-id>

# From a file
s skills.hedgedoc edit <pad-id> /path/to/file.md
```
Edits the pad in-place via the HedgeDoc websocket API (socket.io + OT). No new pad created.

### Get pad info
```bash
s skills.hedgedoc info <pad-id>
```
Returns JSON with title, description, viewcount, timestamps.

## Typical Workflow

1. **Read** the pad: `s skills.hedgedoc read <id>` → get current markdown
2. **Edit** locally: save modified content to a temp file
3. **Write back**: `s skills.hedgedoc edit <id> /tmp/updated.md`
4. **Share**: `https://pad.lassul.us/<id>`

## How it works

The edit command connects to HedgeDoc's socket.io websocket, receives the current document state and revision number, then sends an OT (operational transform) operation that deletes all existing content and inserts the new content. The server acknowledges with an `ack` event.

## Mermaid Diagrams

HedgeDoc renders Mermaid diagrams natively. Use fenced code blocks:

````markdown
```mermaid
graph LR
    A --> B --> C
```
````

Prefer Mermaid over ASCII art for architecture diagrams, flowcharts, etc. in pads.

**Always quote node labels with special characters** — labels containing `/`, `~`, `*`, `+`, `.`, `:`, `(`, `)` must use double quotes: `Node["~/Mail/new/"]` not `Node[~/Mail/new/]`. Unquoted special chars break Mermaid rendering.

## Notes

- `allowFreeURL = true` — pads can have custom slugs
- `defaultPermission = "freely"` — all pads are world-editable via URL
- Edit replaces the entire pad content (full replacement, not partial edit); empty content is refused
- Active browser sessions will see the change in real-time (pushed via socket.io)
- Pad IDs are from the URL: `https://pad.lassul.us/{PADID}`
- Edit uses UTF-16 code unit counting (JavaScript string length) for OT operations
