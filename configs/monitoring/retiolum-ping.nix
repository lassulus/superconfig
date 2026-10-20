# Mesh ping over retiolum: every alwaysOn machine pings every other one each
# minute with a small and a large payload (a broken path can lose only one
# size, e.g. small packets on an udp_confirmed node with pmtu 0). Results go
# to VictoriaMetrics as retiolum_ping_{loss_ratio,rtt_seconds}{to,size}
# (RetiolumPathLoss in alerts.nix). On loss the tinc node state of the peer
# is logged, so VictoriaLogs has it for the moment of the failure.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  inherit (import ./default.nix) alwaysOn;

  name = config.networking.hostName;
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  peers = lib.genAttrs (lib.remove name alwaysOn) (h: kartei.own.${h}.ip6);

  dir = "/run/retiolum-ping";
  tinc = "${config.services.tinc.networks.retiolum.package}/bin/tinc -n retiolum --pidfile=/run/tinc.retiolum.pid";

  ping = pkgs.writeShellApplication {
    name = "retiolum-ping";
    runtimeInputs = with pkgs; [
      coreutils
      fping
      gnugrep
    ];
    text = ''
      declare -A peer=(${lib.concatStrings (lib.mapAttrsToList (h: ip: "[${ip}]=${h} ") peers)})
      mkdir -p ${dir}/failing
      now=$(date +%s)

      for size in 56 1200; do
        fping -6 -q -c 5 -p 200 -t 1000 -b "$size" "''${!peer[@]}" 2>"${dir}/fping.$size" &
      done
      wait

      out=${dir}/metrics.jsonl.tmp
      : >"$out"
      for size in 56 1200; do
        # <addr> : xmt/rcv/%loss = 5/0/100%[, min/avg/max = 1.1/1.2/1.3]
        while read -r addr _ _ _ stats rest; do
          to=''${peer[$addr]:-}
          [ -n "$to" ] || continue
          IFS=/ read -r xmt rcv _ <<<"''${stats%,}"
          loss=$(( (xmt - rcv) * 1000 / xmt ))
          printf '{"metric":"loss_ratio","to":"%s","size":"%s","value":%d.%03d}\n' \
            "$to" "$size" $((loss / 1000)) $((loss % 1000)) >>"$out"
          if [ "$rcv" -gt 0 ]; then
            IFS=/ read -r _ avg _ <<<"''${rest##* }"
            printf '{"metric":"rtt_seconds","to":"%s","size":"%s","value":%se-3}\n' \
              "$to" "$size" "$avg" >>"$out"
          fi

          # failing = more than half lost, as in RetiolumPathLoss. One line
          # on ok -> fail, then every 10 minutes while failing.
          state=${dir}/failing/$to-$size
          if [ $((rcv * 2)) -lt "$xmt" ]; then
            if [ ! -e "$state" ] || [ $((now - $(cat "$state"))) -ge 600 ]; then
              echo "$now" >"$state"
              info=$(${tinc} info "$to" 2>&1 | grep -Ev '^(Node|Node ID|Protocol|Subnets):' | tr -s ' \n' ' ;' || true)
              node=$(${tinc} dump nodes 2>&1 | grep "^$to " || echo "not in node dump")
              echo "loss to=$to size=$size sent=$xmt received=$rcv | info: $info | node: $node"
            fi
          elif [ -e "$state" ]; then
            rm "$state"
            echo "recovered to=$to size=$size sent=$xmt received=$rcv"
          fi
        done <"${dir}/fping.$size"
      done
      mv "$out" ${dir}/metrics.jsonl
    '';
  };
in
lib.mkIf (lib.elem name alwaysOn) {
  systemd.services.retiolum-ping = {
    description = "Ping all alwaysOn machines over retiolum";
    after = [ "tinc.retiolum.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe ping;
      # Vector (a DynamicUser) reads metrics.jsonl
      RuntimeDirectory = "retiolum-ping";
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = true;
      UMask = "0022";
      TimeoutStartSec = "50s";
    };
  };

  systemd.timers.retiolum-ping = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "1s";
    };
  };

  monitoring.extraMetrics = [ "retiolum_ping_metrics" ];

  services.vector.settings = {
    # Only a fresh file: a stopped timer ends the series instead of
    # repeating its last result.
    sources.retiolum_ping_raw = {
      type = "exec";
      mode = "scheduled";
      scheduled.exec_interval_secs = 30;
      command = [
        "${pkgs.findutils}/bin/find"
        dir
        "-name"
        "metrics.jsonl"
        "-mmin"
        "-3"
        "-exec"
        "${pkgs.coreutils}/bin/cat"
        "{}"
        "+"
      ];
      include_stderr = false;
    };
    transforms.retiolum_ping = {
      type = "remap";
      inputs = [ "retiolum_ping_raw" ];
      source = ''
        r = object!(parse_json!(.message))
        . = {
          "metric": string!(r.metric),
          "to": string!(r.to),
          "size": string!(r.size),
          "value": to_float!(r.value),
        }
      '';
      drop_on_error = true;
    };
    transforms.retiolum_ping_metrics = {
      type = "log_to_metric";
      inputs = [ "retiolum_ping" ];
      metrics = [
        {
          type = "gauge";
          field = "value";
          name = "retiolum_ping_{{metric}}";
          tags = {
            host = name;
            to = "{{to}}";
            size = "{{size}}";
          };
        }
      ];
    };
  };
}
