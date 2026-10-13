#!/usr/bin/env bash
# Send audio to the gg23 audio hub on acheron (configs/gg23/audio/hub.nix)
# via ROC while running: loads a ROC sink into pipewire-pulse and makes it the
# default. Ctrl-C / SIGTERM unloads it (streams move back) and restores the
# previous default sink.

set -euo pipefail

SINK=roc-gg23

if [ "$#" -gt 0 ]; then
  echo "usage: gg23-audio (runs until Ctrl-C)" >&2
  exit 1
fi

if pactl list short modules | awk -v s="sink_name=$SINK" '$2 == "module-roc-sink" && index($0, s) { f = 1 } END { exit !f }'; then
  echo "gg23-audio: $SINK is already loaded (another gg23-audio running?)" >&2
  exit 1
fi

prev=$(pactl get-default-sink)

id=$(pactl load-module module-roc-sink \
  sink_name="$SINK" \
  "sink_properties='node.description=\"gg23 (acheron hub)\"'" \
  remote_ip=10.42.0.1 \
  remote_source_port=10001 \
  remote_repair_port=10002 \
  remote_control_port=10003 \
  fec_code=disable)

cleanup() {
  if [ -n "${sleeper-}" ]; then kill "$sleeper" 2>/dev/null || true; fi
  pactl unload-module "$id" || true
  pactl set-default-sink "$prev" || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pactl set-default-sink "$SINK"
echo "sending audio to gg23 hub, Ctrl-C to stop" >&2

sleep infinity &
sleeper=$!
wait
