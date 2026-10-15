# Low-latency audio hub on acheron: everything received plays into the
# virtual "hub" sink, whose monitor is linked to the ROC sinks of the rooms
# selected with `audio-room` or from Home Assistant (MQTT). Senders: any LAN
# machine via ROC (while `gg23-audio` from tools/gg23-audio runs), barnacle
# via AirPlay 2 (shairport-sync + nqptp). Rooms run ./room.nix.
{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  # shodan and icarus have no stable LAN address (dynamic DHCP leases), so
  # send to their static retiolum IPs; tinc's LocalDiscovery keeps that on the
  # LAN.
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  ip4 = n: kartei.own.${n}.ip4;

  rooms = [
    "shodan"
    "icarus"
  ];
  choices = rooms ++ [
    "both"
    "off"
  ];

  mqtt = "-h localhost -u gg23 -P gg23-mqtt";

  # Home Assistant picks these up via MQTT discovery: a select showing the
  # current room plus one button per choice (dashboard / phone shortcuts).
  # Commands are retained, so the bridge restores the last choice on start.
  discovery = [
    {
      topic = "homeassistant/select/audio_room/config";
      config = {
        name = "Audio room";
        unique_id = "acheron_audio_room";
        command_topic = "gg23/audio-room/set";
        state_topic = "gg23/audio-room/state";
        options = choices;
        retain = true;
        icon = "mdi:speaker-multiple";
      };
    }
  ]
  ++ map (c: {
    topic = "homeassistant/button/audio_room_${c}/config";
    config = {
      name = "Audio ${c}";
      unique_id = "acheron_audio_room_${c}";
      command_topic = "gg23/audio-room/set";
      payload_press = c;
      retain = true;
      icon = "mdi:speaker-multiple";
    };
  }) choices;
in
{
  services.pipewire = {
    enable = true;
    systemWide = true;
    audio.enable = true;
    extraConfig.pipewire."10-audio-hub" = {
      "context.properties"."default.clock.quantum" = 256;
      "context.objects" = [
        {
          factory = "adapter";
          args = {
            "factory.name" = "support.null-audio-sink";
            "node.name" = "hub";
            "node.description" = "Audio hub";
            "media.class" = "Audio/Sink";
            "audio.position" = [
              "FL"
              "FR"
            ];
          };
        }
      ];
      "context.modules" = [
        {
          # from any LAN sender (`gg23-audio`); roc mixes concurrent
          # sender sessions. Only reachable via int0, et0 is closed.
          name = "libpipewire-module-roc-source";
          args = {
            "local.ip" = "0.0.0.0";
            "local.source.port" = 10001;
            "local.repair.port" = 10002;
            "local.control.port" = 10003;
            "fec.code" = "disable";
            "sess.latency.msec" = 30;
            "source.name" = "roc-lan";
            "source.props" = {
              "node.description" = "LAN (ROC)";
              "target.object" = "hub";
            };
          };
        }
      ]
      ++ map (r: {
        name = "libpipewire-module-roc-sink";
        args = {
          "remote.ip" = ip4 r;
          "remote.source.port" = 10001;
          "remote.repair.port" = 10002;
          "remote.control.port" = 10003;
          "fec.code" = "disable";
          "sink.name" = "roc-${r}";
          "sink.props"."node.description" = "${r} (ROC)";
        };
      }) rooms;
    };
  };

  # AirPlay 2: macOS drives classic AirPlay 1 receivers through a legacy path
  # that can wedge (endpoint stays half-active after switching outputs, and
  # re-picking it fails with -16727 until AirPlayXPCHelper restarts).
  services.shairport-sync = {
    enable = true;
    package = pkgs.shairport-sync-airplay2;
    settings = {
      general = {
        name = "gg23";
        output_backend = "pipewire";
        # play early by about the hub -> room ROC hop, so AirPlay video
        # stays in sync in the rooms
        audio_backend_latency_offset_in_seconds = -0.04;
      };
      pipewire.sink_target = "hub";
    };
  };
  users.users.shairport.extraGroups = [ "pipewire" ];

  # PTP timing companion AirPlay 2 needs (UDP 319/320; int0 is trusted, et0
  # stays closed). The unit comes from the package.
  systemd.packages = [ pkgs.nqptp ];
  systemd.services.nqptp.wantedBy = [ "multi-user.target" ];
  systemd.services.shairport-sync = {
    wants = [ "nqptp.service" ];
    after = [ "nqptp.service" ];
  };

  # mDNS for AirPlay on the LAN only; int0 is trusted, et0 must stay closed
  services.avahi = {
    allowInterfaces = [ "int0" ];
    openFirewall = false;
  };

  # MQTT -> pipewire links, so Home Assistant (in podman) needs no access to
  # pipewire. Restarted with pipewire, the retained command restores the room.
  systemd.services.audio-room = {
    wantedBy = [
      "multi-user.target"
      "pipewire.service"
    ];
    bindsTo = [ "pipewire.service" ];
    after = [
      "pipewire.service"
      "mosquitto.service"
    ];
    path = [
      config.services.pipewire.package
      pkgs.mosquitto
    ];
    script = ''
      ${lib.concatMapStrings (d: ''
        mosquitto_pub ${mqtt} -r -t ${d.topic} -m ${lib.escapeShellArg (builtins.toJSON d.config)}
      '') discovery}
      route() {
        for r in ${toString rooms}; do
          pw-link -d hub "roc-$r" 2>/dev/null
          case "$1" in "$r" | both)
            i=0
            until pw-link hub "roc-$r"; do
              i=$((i + 1))
              [ "$i" -lt 10 ] || return 1
              sleep 1
            done
            ;;
          esac
        done
      }
      mosquitto_sub ${mqtt} -t gg23/audio-room/set | while read -r room; do
        case "$room" in
          ${lib.concatStringsSep " | " choices}) ;;
          *) echo "ignoring $room" >&2; continue ;;
        esac
        route "$room" && mosquitto_pub ${mqtt} -r -t gg23/audio-room/state -m "$room"
      done
    '';
    serviceConfig = {
      DynamicUser = true;
      SupplementaryGroups = [ "pipewire" ];
      Restart = "always";
      RestartSec = 2;
    };
  };

  environment.systemPackages = [
    (pkgs.writers.writeDashBin "audio-room" ''
      case "''${1-}" in
        ${lib.concatStringsSep " | " choices})
          exec ${pkgs.mosquitto}/bin/mosquitto_pub ${mqtt} -r -t gg23/audio-room/set -m "$1"
          ;;
        *)
          echo "usage: audio-room ${lib.concatStringsSep "|" choices}" >&2
          exit 1
          ;;
      esac
    '')
  ];
}
