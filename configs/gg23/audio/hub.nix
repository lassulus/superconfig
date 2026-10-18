# Low-latency audio hub on acheron: audio-matrix (./matrix.py) links each
# received source to the ROC sinks of the rooms switched on for it in Home
# Assistant (MQTT), which also sets a volume per room. Sources: any LAN
# machine via ROC (while `gg23-audio` from tools/gg23-audio runs), barnacle
# via AirPlay 2 (shairport-sync + nqptp), phones via Bluetooth A2DP (paired
# during the window opened by the "Bluetooth pairing" button) and
# radio.lassul.us. Rooms run ./room.nix.
{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  # Rooms are addressed by their static retiolum IPs (shodan and icarus have
  # dynamic DHCP leases); tinc's LocalDiscovery keeps that on the LAN.
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  ip4 = n: kartei.own.${n}.ip4;

  # room machine -> speaker name in Home Assistant
  rooms = {
    shodan = "Kitchen";
    icarus = "Bath";
    styx = "Living room";
  };

  mqtt = "-h localhost -u gg23 -P gg23-mqtt";

  # Home Assistant shows a switch per source and room and a volume per room
  # (./matrix.py); the fixed sources by node name, Bluetooth phones come and
  # go. A source starts on all rooms unless it lists `rooms`.
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
        # where Snapcast played it before
        radio = {
          node = "radio";
          label = "Radio";
          rooms = [
            "icarus"
            "shodan"
          ];
        };
      };
      state = "/var/lib/audio-matrix/routes.json";
      volumes = "/var/lib/audio-matrix/volumes.json";
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

  # "Audio" dashboard in Home Assistant (configs/hass loads /config/packages):
  # one grid of a column per room (volume, all off) and a row per source
  # (all on/off), cells toggle the audio_route switches. Rows come from the
  # switches of the first room via auto-entities (HACS), so Bluetooth phones
  # appear while connected.
  roomNames = lib.attrNames rooms;
  anchor = builtins.head roomNames;
  # button calling `service` on the route switches in Jinja list `targets`
  allButton =
    name: icon: service: targets:
    ''{"type": "button", "name": "${name}", "icon": "${icon}", "show_name": true, "icon_height": "24px", "tap_action": {"action": "perform-action", "perform_action": "${service}", "target": {"entity_id": ${targets}}}, "hold_action": {"action": "none"}}'';
  roomHeader =
    r:
    ''{% set col = states.switch | selectattr('entity_id', 'search', '^switch\\.audio_route_.*_${r}$') | map(attribute='entity_id') | list %}{% set ns.out = ns.out + [{"type": "vertical-stack", "cards": [{"type": "tile", "entity": "number.audio_volume_${r}", "name": "${rooms.${r}}", "icon": "mdi:speaker", "features": [{"type": "numeric-input", "style": "slider"}]}, ${
      allButton "All off" "mdi:volume-off" "switch.turn_off" "col"
    }]}] %}'';
  # crossed out speaker when off, so on/off differ in shape too
  routeCell =
    r:
    let
      id = ''"switch.audio_route_" ~ k ~ "_${r}"'';
    in
    ''{"type": "button", "entity": ${id}, "name": "${rooms.${r}}", "show_name": false, "icon": ("mdi:speaker" if is_state(${id}, "on") else "mdi:speaker-off"), "icon_height": "64px", "tap_action": {"action": "toggle"}, "hold_action": {"action": "none"}}'';
  matrix = lib.concatStrings (
    [
      "{% set ns = namespace(out=[]) %}"
      ''{% set ns.out = ns.out + [{"type": "markdown", "content": "### Source / Room"}] %}''
    ]
    ++ map roomHeader roomNames
    ++ [
      "{% for e in states.switch | selectattr('entity_id', 'search', '^switch\\\\.audio_route_.*_${anchor}$') | sort(attribute='attributes.source') | sort(attribute='attributes.kind') %}"
      "{% set icon = {'bluetooth': 'mdi:bluetooth', 'airplay': 'mdi:cast-audio', 'lan': 'mdi:lan', 'radio': 'mdi:radio'}.get(e.attributes.kind, 'mdi:music') %}"
      # switch.audio_route_<key>_<anchor>
      "{% set k = e.entity_id[${toString (builtins.stringLength "switch.audio_route_")}:-${toString (builtins.stringLength "_${anchor}")}] %}"
      "{% set row = [${
        lib.concatMapStringsSep ", " (r: ''"switch.audio_route_" ~ k ~ "_${r}"'') roomNames
      }] %}"
      ''{% set ns.out = ns.out + [{"type": "vertical-stack", "cards": [{"type": "button", "name": e.attributes.source, "icon": icon, "show_state": false, "icon_height": "40px", "tap_action": {"action": "none"}, "hold_action": {"action": "none"}}, {"type": "grid", "columns": 2, "square": false, "cards": [${
        allButton "All on" "mdi:volume-high" "switch.turn_on" "row"
      }, ${allButton "All off" "mdi:volume-off" "switch.turn_off" "row"}]}]}] %}''
      "{% set ns.out = ns.out + [${lib.concatMapStringsSep ", " routeCell roomNames}] %}"
      "{% endfor %}{{ ns.out }}"
    ]
  );
  audioDashboard = {
    title = "Audio";
    views = [
      {
        title = "Audio";
        path = "routing";
        icon = "mdi:speaker-multiple";
        type = "sections";
        max_columns = 3;
        sections = [
          {
            type = "grid";
            column_span = 3;
            cards = [
              {
                type = "heading";
                heading = "Where does the audio go?";
                icon = "mdi:speaker-multiple";
              }
              {
                type = "markdown";
                text_only = true;
                content = "Tap a speaker to send that source there. Bluetooth `gg23`, AirPlay `gg23`, LAN via `s gg23-audio` and the radio; Bluetooth devices appear while connected.";
              }
              {
                type = "custom:auto-entities";
                grid_options.columns = "full";
                card = {
                  type = "grid";
                  columns = 1 + builtins.length roomNames;
                  square = false;
                };
                card_param = "cards";
                filter.template = matrix;
                show_empty = true;
              }
            ];
          }
          {
            type = "grid";
            column_span = 3;
            cards = [
              {
                type = "heading";
                heading = "Bluetooth";
                icon = "mdi:bluetooth";
                heading_style = "subtitle";
              }
              {
                type = "button";
                name = "Pair Bluetooth (${toString pairingTimeout} s)";
                icon = "mdi:bluetooth-connect";
                show_state = false;
                grid_options.columns = 6;
                tap_action = {
                  action = "perform-action";
                  perform_action = "button.press";
                  target.entity_id = "button.bluetooth_pairing";
                };
              }
              {
                type = "tile";
                entity = "binary_sensor.bluetooth_pairing";
                name = "Pairing window";
                grid_options.columns = 6;
              }
            ];
          }
        ];
      }
    ];
  };
  json = name: value: pkgs.writeText name (builtins.toJSON value);
in
{
  virtualisation.oci-containers.containers.homeassistant.volumes = [
    "${
      json "audio.yaml" {
        lovelace.dashboards.audio-routing = {
          mode = "yaml";
          title = "Audio";
          icon = "mdi:speaker-multiple";
          show_in_sidebar = true;
          filename = "dashboards/audio.yaml";
        };
      }
    }:/config/packages/audio.yaml:ro"
    "${json "audio-dashboard.yaml" audioDashboard}:/config/dashboards/audio.yaml:ro"
  ];

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

  # radio.lassul.us as a hub source, playing all the time; audio-matrix
  # decides where it is heard
  systemd.services.radio = {
    wantedBy = [
      "multi-user.target"
      "pipewire.service"
    ];
    bindsTo = [ "pipewire.service" ];
    after = [
      "pipewire.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    # linked only by audio-matrix
    environment.PIPEWIRE_AUTOCONNECT = "false";
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.mpv)
        "--no-video"
        "--no-terminal"
        "--ao=pipewire"
        # node.name, see `sources` in matrixConfig
        "--audio-client-name=radio"
        # keep going through stream hiccups and server restarts
        "--loop-playlist=inf"
        "http://radio.lassul.us/radio.ogg"
      ];
      DynamicUser = true;
      SupplementaryGroups = [ "pipewire" ];
      Restart = "always";
      RestartSec = 5;
    };
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
    path = [
      config.services.pipewire.package
      config.services.pipewire.wireplumber.package # wpctl, for room volumes
    ];
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
