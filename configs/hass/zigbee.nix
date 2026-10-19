{
  # symlink the zigbee controller
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="0451", ATTRS{idProduct}=="16a8", SYMLINK+="cc2531", MODE="0660", GROUP="dialout"
    SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="cc2652", MODE="0660", GROUP="dialout"
  '';

  # needed to use unstable package
  systemd.services.zigbee2mqtt.environment.ZIGBEE2MQTT_DATA = "/var/lib/zigbee2mqtt";

  services.zigbee2mqtt = {
    enable = true;
    settings = {
      homeassistant.enabled = true;
      frontend.port = 1337;
      experimental.new_api = true;
      permit_join = false;
      mqtt = {
        discovery = true;
        base_topic = "zigbee";
        server = "mqtt://127.0.0.1";
        user = "gg23";
        password = "gg23-mqtt";
      };
      serial = {
        port = "/dev/cc2652";
        adapter = "zstack";
        # disable_led = true;
      };
      advanced = {
        pan_id = 4222;
      };
      devices = {
        # lights https://www.zigbee2mqtt.io/devices/9290022166.html#philips-9290022166
        "0x0017880106ed3bd8".friendly_name = "l_wohn";
        "0x0017880108327622".friendly_name = "l_essen";
        "0x0017880106ee2865".friendly_name = "l_bett";
        "0x00178801082e9f2f".friendly_name = "l_nass";

        # lights https://www.zigbee2mqtt.io/devices/9290024688.html#philips-9290024688
        "0x001788010c0b9a7b".friendly_name = "l_flur";

        # switches https://www.zigbee2mqtt.io/devices/324131092621.html#philips-324131092621
        "0x00178801086ac38c".friendly_name = "i_wohn";
        "0x00178801086ad1fb".friendly_name = "i_essen";
        "0x00178801086ac373".friendly_name = "i_nass";

        # motion sensors https://www.zigbee2mqtt.io/devices/9290012607.html#philips-9290012607
        "0x0017880106f772f2".friendly_name = "s_essen";
        "0x0017880106f77f30".friendly_name = "s_nass";

        # motion sensors https://www.zigbee2mqtt.io/devices/SNZB-03.html#sonoff-snzb-03
        "0x00124b002a68be83".friendly_name = "s_wohn";
        "0x00124b002a6890ef".friendly_name = "s_nass2";

        # motion sensors https://www.zigbee2mqtt.io/devices/RTCGQ11LM.html#aqara-rtcgq11lm
        "0x00158d0005468b98".friendly_name = "s_flur";

        # heat https://www.zigbee2mqtt.io/devices/701721.html#popp-701721
        "0x842e14fffe27109a".friendly_name = "t_wohn";
        "0x842e14fffe269a73".friendly_name = "t_nass";
        "0x842e14fffe269a56".friendly_name = "t_bett";

        # door sensor https://www.zigbee2mqtt.io/devices/SNZB-04.html#sonoff-snzb-04
        "0x00124b002a62eb66".friendly_name = "main_door";
        "0x00124b002a6306fd".friendly_name = "window_essen";
        "0x00124b0022cd2b1d".friendly_name = "window_nass";
        "0x00124b002932d7c2".friendly_name = "window_wohn";
        "0x00124b002a62fd46".friendly_name = "window_bett";

        "0x00124b002a62ee91".friendly_name = "door_essen";
        "0x00124b002a6301df".friendly_name = "door_nass";
        "0x00124b002932f2bf".friendly_name = "door_bett";
        "0x00124b002a62f231".friendly_name = "door_wohn";

        # button https://www.zigbee2mqtt.io/devices/8718699693985.html#philips-8718699693985
        "0x0017880108016e3e".friendly_name = "going_out_button";

        # rotation https://www.zigbee2mqtt.io/devices/E1744.html
        "0x8cf681fffe065493" = {
          friendly_name = "r_test";
          device_id = "r_test";
          simulated_brightness = {
            delta = 2;
            interval = 100;
          };
        };

      };
    };
  };

  # devices, groups and the coordinator backup; database.db is JSON, not
  # SQLite, so a plain copy is fine
  lass.backup.state.zigbee2mqtt = {
    folders = [ "/var/lib/zigbee2mqtt" ];
    exclude = [ "/var/lib/zigbee2mqtt/log" ];
  };
}
