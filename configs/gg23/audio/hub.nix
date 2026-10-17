# Low-latency audio hub on acheron: audio-matrix (./matrix.py) links each
# received source to the ROC sinks of the rooms switched on for it in Home
# Assistant (MQTT). Senders: any LAN machine via ROC (while `gg23-audio` from
# tools/gg23-audio runs), barnacle via AirPlay 2 (shairport-sync + nqptp),
# phones via Bluetooth A2DP (paired during the window opened by the
# "Bluetooth pairing" button). Rooms run ./room.nix.
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

  # room machine -> speaker name in Home Assistant
  rooms = {
    shodan = "Kitchen";
    icarus = "Bath";
  };

  mqtt = "-h localhost -u gg23 -P gg23-mqtt";

  # Home Assistant shows a switch per source and room (./matrix.py); the
  # fixed sources by node name, Bluetooth phones come and go
  matrixConfig = pkgs.writeText "audio-matrix.json" (
    builtins.toJSON {
      mqtt = {
        host = "localhost";
        user = "gg23";
        password = "gg23-mqtt";
      };
      speakers = lib.mapAttrs (r: label: {
        node = "roc-${r}";
        inherit label;
      }) rooms;
      sources = {
        airplay = {
          node = "Shairport Sync";
          label = "AirPlay";
        };
        lan = {
          node = "roc-lan";
          label = "LAN";
        };
      };
      state = "/var/lib/audio-matrix/routes.json";
    }
  );

  # seconds acheron stays discoverable and pairable after the button press
  pairingTimeout = 120;

  bluetoothDiscovery = [
    {
      topic = "homeassistant/button/bluetooth_pairing/config";
      config = {
        name = "Bluetooth pairing";
        unique_id = "acheron_bluetooth_pairing";
        command_topic = "gg23/bluetooth-pairing/set";
        icon = "mdi:bluetooth-connect";
      };
    }
    {
      topic = "homeassistant/binary_sensor/bluetooth_pairing/config";
      config = {
        name = "Bluetooth pairing";
        unique_id = "acheron_bluetooth_pairing_state";
        state_topic = "gg23/bluetooth-pairing/state";
        icon = "mdi:bluetooth-connect";
      };
    }
  ];
in
{
  services.pipewire = {
    enable = true;
    systemWide = true;
    audio.enable = true;
    extraConfig.pipewire."10-audio-hub" = {
      "context.properties"."default.clock.quantum" = 256;
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
              "node.autoconnect" = false;
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
      }) (lib.attrNames rooms);
    };
    # acheron is only an A2DP sink (no headset or LE audio roles); like the
    # other sources, phones are linked only by audio-matrix
    wireplumber.extraConfig."10-bluetooth-hub" = {
      "monitor.bluez.properties" = {
        "bluez5.roles" = [ "a2dp_sink" ];
        # phones in HD audio mode pick other codecs, whose input node fails
        "bluez5.codecs" = [
          "sbc"
          "sbc_xq"
          "aac"
        ];
      };
      "monitor.bluez.rules" = [
        {
          matches = [ { "node.name" = "~bluez_input.*"; } ];
          actions.update-props."node.autoconnect" = false;
        }
      ];
    };
  };

  # The UB500 dongle (RTL8761BU) firmware comes from linux-firmware.
  # Discoverable and pairable only after the "Bluetooth pairing" button.
  hardware.bluetooth = {
    enable = true;
    # the hostname plugin would override Name and Class with the hostname
    # and chassis type
    disabledPlugins = [ "hostname" ];
    settings.General = {
      Name = "gg23";
      # audio/video major class, loudspeaker, so phones show a speaker
      Class = "0x200414";
      DiscoverableTimeout = pairingTimeout;
      PairableTimeout = pairingTimeout;
      # a phone that forgot acheron can pair again during the window
      JustWorksRepairing = "always";
    };
  };

  # Accepts pairing without PIN (NoInputNoOutput is just works) and service
  # connections of paired devices.
  systemd.services.bluetooth-agent = {
    wantedBy = [ "bluetooth.service" ];
    bindsTo = [ "bluetooth.service" ];
    after = [ "bluetooth.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.bluez-tools}/bin/bt-agent -c NoInputNoOutput";
      DynamicUser = true;
      Restart = "always";
      RestartSec = 2;
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
        # play early by about the acheron -> room ROC hop, so AirPlay video
        # stays in sync in the rooms
        audio_backend_latency_offset_in_seconds = -0.04;
      };
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
    # linked only by audio-matrix
    environment.PIPEWIRE_AUTOCONNECT = "false";
  };

  # mDNS for AirPlay on the LAN only; int0 is trusted, et0 must stay closed
  services.avahi = {
    allowInterfaces = [ "int0" ];
    openFirewall = false;
  };

  # MQTT -> pipewire links, so Home Assistant (in podman) needs no access to
  # pipewire. Restarted with pipewire, the state file restores the routes.
  systemd.services.audio-matrix = {
    wantedBy = [
      "multi-user.target"
      "pipewire.service"
    ];
    bindsTo = [ "pipewire.service" ];
    after = [
      "pipewire.service"
      "mosquitto.service"
    ];
    path = [ config.services.pipewire.package ];
    serviceConfig = {
      ExecStart = "${
        pkgs.writers.writePython3 "audio-matrix" {
          libraries = [ pkgs.python3Packages.paho-mqtt ];
          flakeIgnore = [ "E501" ];
        } ./matrix.py
      } ${matrixConfig}";
      DynamicUser = true;
      SupplementaryGroups = [ "pipewire" ];
      StateDirectory = "audio-matrix";
      Restart = "always";
      RestartSec = 2;
    };
  };

  # MQTT button -> pairing window. BlueZ itself turns discoverable/pairable
  # off after pairingTimeout; then devices bonded in the window get trusted,
  # so they reconnect without the agent, and the state goes back to OFF.
  systemd.services.bluetooth-pairing = {
    wantedBy = [ "bluetooth.service" ];
    bindsTo = [ "bluetooth.service" ];
    after = [
      "bluetooth.service"
      "mosquitto.service"
    ];
    path = [
      pkgs.mosquitto
      config.systemd.package
    ];
    script = ''
      ${lib.concatMapStrings (d: ''
        mosquitto_pub ${mqtt} -r -t ${d.topic} -m ${lib.escapeShellArg (builtins.toJSON d.config)}
      '') bluetoothDiscovery}
      adapter() {
        busctl set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 "$1" b "$2"
      }
      state() {
        mosquitto_pub ${mqtt} -r -t gg23/bluetooth-pairing/state -m "$1"
      }
      trust() {
        for d in $(busctl tree --list org.bluez | grep '/dev_[0-9A-F_]*$'); do
          if [ "$(busctl get-property org.bluez "$d" org.bluez.Device1 Bonded)" = "b true" ]; then
            busctl set-property org.bluez "$d" org.bluez.Device1 Trusted b true
          fi
        done
      }
      # bluetoothd powers hci0 on (AutoEnable) only after it shows up
      until [ "$(busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered 2>/dev/null)" = "b true" ]; do
        sleep 1
      done
      adapter Discoverable false
      adapter Pairable false
      trust
      state OFF
      mosquitto_sub ${mqtt} -t gg23/bluetooth-pairing/set | while read -r _; do
        if [ -n "''${window-}" ] && kill -0 "$window" 2>/dev/null; then
          continue
        fi
        adapter Pairable true
        adapter Discoverable true
        state ON
        (sleep ${toString pairingTimeout}; trust; state OFF) &
        window=$!
      done
    '';
    serviceConfig = {
      DynamicUser = true;
      Restart = "always";
      RestartSec = 2;
    };
  };
}
