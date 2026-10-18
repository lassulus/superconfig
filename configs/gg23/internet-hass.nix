# Home Assistant side of ./internet.nix: sensors that query VictoriaMetrics on
# styx (the gg23 monitoring server) and an "Internet" dashboard explaining
# why the internet is slow. Both are mounted into the container as a package
# and a YAML dashboard (configs/hass loads /config/packages); generated as
# JSON, which HA's YAML loader reads as well.
{
  lib,
  pkgs,
  self,
  ...
}:
let
  inherit (import ../monitoring/default.nix) ports;
  # IPv4: VictoriaMetrics doesn't listen on IPv6, styx.r resolves to it first.
  vm = "http://${self.inputs.kartei.hosts.styx.nets.retiolum.ip4.addr}:${toString ports.victoriametrics}/api/v1/query";

  # booked Vodafone cable rate in Mbit/s (speedtests from acheron: ~920/50)
  line = {
    down = 1000;
    up = 50;
  };

  ping = sel: {
    latency = ''avg(rate(smokeping_response_duration_seconds_sum{host="acheron",${sel}}[5m]) / rate(smokeping_response_duration_seconds_count{host="acheron",${sel}}[5m])) * 1000'';
    p95 = ''histogram_quantile(0.95, sum(rate(smokeping_response_duration_seconds_bucket{host="acheron",${sel}}[5m])) by (le)) * 1000'';
    loss = ''100 * (1 - sum(rate(smokeping_response_duration_seconds_count{host="acheron",${sel}}[5m])) / sum(rate(smokeping_requests_total{host="acheron",${sel}}[5m])))'';
  };
  internet = ping ''target_name=~"cloudflare|google"'';
  cmts = ping ''target_name="cmts"'';
  station = ping ''target_name="station"'';
  wan = dir: ''rate(host_network_${dir}_bytes_total{host="acheron",device="et0"}[2m]) * 8 / 1e6'';
  docsis = ''{host="acheron",channel_type="SC-QAM"}'';

  # id -> sensor entity. `name` ("Internet <name>") is what HA derives the
  # entity id from (see `e`), so it must not change; `label` is the display
  # name (homeassistant.customize friendly_name).
  sensors = {
    latency = {
      name = "Latency";
      label = "Latency to internet";
      query = internet.latency;
      unit = "ms";
      icon = "mdi:timer-outline";
    };
    latency_p95 = {
      name = "Latency p95";
      label = "Latency spikes (p95)";
      query = internet.p95;
      unit = "ms";
      icon = "mdi:timer-alert-outline";
    };
    loss = {
      name = "Packet loss";
      label = "Packet loss to internet";
      query = internet.loss;
      unit = "%";
      icon = "mdi:lan-disconnect";
    };
    cmts_latency = {
      name = "Cable latency";
      label = "Latency over the cable";
      query = cmts.latency;
      unit = "ms";
      icon = "mdi:timer-outline";
    };
    cmts_loss = {
      name = "Cable packet loss";
      label = "Packet loss over the cable";
      query = cmts.loss;
      unit = "%";
      icon = "mdi:lan-disconnect";
    };
    station_latency = {
      name = "Station latency";
      label = "Latency to the router";
      query = station.latency;
      unit = "ms";
      icon = "mdi:router-network";
    };
    station_loss = {
      name = "Station packet loss";
      label = "Packet loss to the router";
      query = station.loss;
      unit = "%";
      icon = "mdi:router-network";
    };
    download = {
      name = "Download";
      label = "Download";
      query = wan "receive";
      unit = "Mbit/s";
      device_class = "data_rate";
      icon = "mdi:download";
    };
    upload = {
      name = "Upload";
      label = "Upload";
      query = wan "transmit";
      unit = "Mbit/s";
      device_class = "data_rate";
      icon = "mdi:upload";
    };
    # hourly, ./internet-speedtest.nix; last result within 2h
    speedtest_download = {
      name = "Speedtest download";
      label = "Speedtest download";
      query = ''last_over_time(speedtest_download_bits_per_second{host="acheron"}[2h]) / 1e6'';
      unit = "Mbit/s";
      device_class = "data_rate";
      icon = "mdi:speedometer";
    };
    speedtest_upload = {
      name = "Speedtest upload";
      label = "Speedtest upload";
      query = ''last_over_time(speedtest_upload_bits_per_second{host="acheron"}[2h]) / 1e6'';
      unit = "Mbit/s";
      device_class = "data_rate";
      icon = "mdi:speedometer";
    };
    speedtest_latency = {
      name = "Speedtest latency";
      label = "Speedtest latency";
      query = ''last_over_time(speedtest_latency_seconds{host="acheron"}[2h]) * 1000'';
      unit = "ms";
      icon = "mdi:timer-outline";
    };
    ds_snr_min = {
      name = "Downstream SNR min";
      label = "Downstream SNR min";
      query = ''min(vodafone_station_docsis_snr_db{direction="downstream",host="acheron"})'';
      unit = "dB";
      icon = "mdi:signal";
    };
    ds_power_min = {
      name = "Downstream power min";
      label = "Downstream power min";
      query = ''min(vodafone_station_docsis_power_dbmv{direction="downstream",${lib.removePrefix "{" docsis})'';
      unit = "dBmV";
      icon = "mdi:arrow-down-bold";
    };
    ds_power_max = {
      name = "Downstream power max";
      label = "Downstream power max";
      query = ''max(vodafone_station_docsis_power_dbmv{direction="downstream",${lib.removePrefix "{" docsis})'';
      unit = "dBmV";
      icon = "mdi:arrow-down-bold";
    };
    us_power_max = {
      name = "Upstream power max";
      label = "Upstream power max";
      query = ''max(vodafone_station_docsis_power_dbmv{direction="upstream",${lib.removePrefix "{" docsis})'';
      unit = "dBmV";
      icon = "mdi:arrow-up-bold";
    };
    unlocked = {
      name = "Unlocked channels";
      label = "DOCSIS channels not locked";
      query = ''count(vodafone_station_docsis_locked{host="acheron"} == 0) or vector(0)'';
      icon = "mdi:lock-open-alert";
      format = "int";
    };
    docsis_online = {
      name = "DOCSIS online";
      label = "Cable modem online";
      query = ''max(vodafone_station_docsis_online{host="acheron"})'';
      icon = "mdi:cable-data";
      format = "yesno";
    };
    station_up = {
      name = "Station scrape";
      label = "Router stats readable";
      query = ''max(vodafone_station_up{host="acheron"})'';
      icon = "mdi:router-wireless";
      format = "yesno";
    };
    station_uptime = {
      name = "Station uptime";
      label = "Router uptime";
      query = ''max(vodafone_station_uptime_seconds{host="acheron"})'';
      unit = "s";
      device_class = "duration";
      icon = "mdi:restart";
    };
  };

  restEntry =
    id: s:
    let
      v = "(value_json.data.result[0].value[1] | float)";
      format = s.format or "float";
    in
    {
      resource = vm;
      params.query = s.query;
      scan_interval = 60;
      timeout = 20;
      sensor = [
        (
          {
            name = "Internet ${s.name}";
            unique_id = "gg23_internet_${id}";
            # no series yet (e.g. rate() right after a restart): unavailable
            availability = "{{ value_json is defined and value_json.data.result | length > 0 }}";
            value_template =
              {
                float = "{{ ${v} | round(2) }}";
                int = "{{ ${v} | int }}";
                yesno = "{{ 'yes' if ${v} > 0 else 'no' }}";
              }
              .${format};
            inherit (s) icon;
          }
          // lib.optionalAttrs (format != "yesno") { state_class = "measurement"; }
          // lib.optionalAttrs (s ? unit) { unit_of_measurement = s.unit; }
          // lib.optionalAttrs (s ? device_class) { inherit (s) device_class; }
        )
      ];
    };

  # HA derives the entity id from the name ("Internet Latency p95" ->
  # sensor.internet_latency_p95); unique_id doesn't influence it.
  e =
    id:
    "sensor.internet_" + lib.toLower (lib.replaceStrings [ " " ] [ "_" ] (sensors.${id}.name or id));

  # Each check: the problem it names, in the order things are upstream of
  # each other (LAN cable -> router -> cable segment -> backbone). Thresholds
  # for DOCSIS levels follow the usual Vodafone cable level tables.
  diagnosis = ''
    {%- set n = namespace(p=[]) -%}
    {%- if is_state('${e "station_up"}', 'no') -%}
      {%- set n.p = n.p + ['Router stats not readable'] -%}
    {%- endif -%}
    {%- if is_state('${e "docsis_online"}', 'no') -%}
      {%- set n.p = n.p + ['Cable modem not DOCSIS online'] -%}
    {%- endif -%}
    {%- if states('${e "station_loss"}') | float(0) > 1 -%}
      {%- set n.p = n.p + ['Packet loss to the router ' ~ states('${e "station_loss"}') ~ '% (LAN cable/port)'] -%}
    {%- endif -%}
    {%- if states('${e "unlocked"}') | float(0) > 0 -%}
      {%- set n.p = n.p + [states('${e "unlocked"}') | int ~ ' DOCSIS channels unlocked'] -%}
    {%- endif -%}
    {%- if states('${e "ds_snr_min"}') | float(99) < 33 -%}
      {%- set n.p = n.p + ['Downstream SNR low (' ~ states('${e "ds_snr_min"}') ~ ' dB)'] -%}
    {%- endif -%}
    {%- if states('${e "ds_power_min"}') | float(0) < -4 or states('${e "ds_power_max"}') | float(0) > 13 -%}
      {%- set n.p = n.p + ['Downstream level out of range (' ~ states('${e "ds_power_min"}') ~ '..' ~ states('${e "ds_power_max"}') ~ ' dBmV)'] -%}
    {%- endif -%}
    {%- if states('${e "us_power_max"}') | float(0) > 51 -%}
      {%- set n.p = n.p + ['Upstream level high (' ~ states('${e "us_power_max"}') ~ ' dBmV): return path attenuated/noisy'] -%}
    {%- endif -%}
    {%- if states('${e "cmts_loss"}') | float(0) > 1 -%}
      {%- set n.p = n.p + ['Loss on the cable segment ' ~ states('${e "cmts_loss"}') ~ '%'] -%}
    {%- endif -%}
    {%- if states('${e "cmts_latency"}') | float(0) > 30 -%}
      {%- set n.p = n.p + ['Cable segment slow (' ~ states('${e "cmts_latency"}') ~ ' ms to CMTS): node congested'] -%}
    {%- endif -%}
    {%- if states('${e "loss"}') | float(0) > 1 and states('${e "cmts_loss"}') | float(0) <= 1 -%}
      {%- set n.p = n.p + ['Loss behind the CMTS ' ~ states('${e "loss"}') ~ '% (Vodafone backbone)'] -%}
    {%- endif -%}
    {#- the hourly speedtest saturates the line itself: skip the 5 min window after a result -#}
    {%- set st = states['${e "speedtest_download"}'] -%}
    {%- set after_speedtest = st is not none and (now() - st.last_changed).total_seconds() < 420 -%}
    {%- if states('${e "latency_p95"}') | float(0) > 60 and not after_speedtest -%}
      {%- set n.p = n.p + ['Latency spikes (p95 ' ~ states('${e "latency_p95"}') ~ ' ms) at ' ~ states('${e "download"}') ~ '/' ~ states('${e "upload"}') ~ ' Mbit/s: bufferbloat or congestion'] -%}
    {%- endif -%}
    {%- if states('${e "station_uptime"}') | float(99999) < 3600 -%}
      {%- set n.p = n.p + ['Router rebooted in the last hour'] -%}
    {%- endif -%}
    {%- if states('${e "speedtest_download"}') | float(9999) < 0.3 * ${toString line.down} -%}
      {%- set n.p = n.p + ['Speedtest only ' ~ states('${e "speedtest_download"}') ~ ' of ${toString line.down} Mbit/s down'] -%}
    {%- endif -%}
    {%- if states('${e "speedtest_upload"}') | float(9999) < 0.3 * ${toString line.up} -%}
      {%- set n.p = n.p + ['Speedtest only ' ~ states('${e "speedtest_upload"}') ~ ' of ${toString line.up} Mbit/s up'] -%}
    {%- endif -%}
  '';

  package = {
    rest = lib.mapAttrsToList restEntry sensors;
    # display names; `name` stays what the entity ids were derived from
    homeassistant.customize = lib.mapAttrs' (
      id: s: lib.nameValuePair (e id) { friendly_name = s.label; }
    ) sensors;
    template = [
      {
        sensor = [
          {
            name = "Internet diagnosis";
            unique_id = "gg23_internet_diagnosis";
            icon = "mdi:stethoscope";
            # the problem itself when there is one, else the count
            state = "${diagnosis}{{ 'OK' if not n.p else n.p[0] if n.p | count == 1 else n.p | count ~ ' problems' }}";
            attributes.problems = "${diagnosis}{{ ('- ' ~ n.p | join('\\n- ')) if n.p else 'nothing found' }}";
          }
        ];
      }
    ];
    lovelace.dashboards.internet-gg23 = {
      mode = "yaml";
      title = "Internet";
      icon = "mdi:wan";
      show_in_sidebar = true;
      filename = "dashboards/internet.yaml";
    };
  };

  # history-graph; rows: [ id legend-name ] in display order
  graph = title: hours: rows: {
    type = "history-graph";
    inherit title;
    hours_to_show = hours;
    entities = map (r: {
      entity = e (builtins.elemAt r 0);
      name = builtins.elemAt r 1;
    }) rows;
  };

  dashboard = {
    title = "Internet";
    views = [
      {
        title = "Internet";
        path = "internet";
        type = "sections";
        max_columns = 3;
        sections = [
          {
            type = "grid";
            column_span = 3;
            cards = [
              # apexcharts-card is installed through HACS (not declarative)
              {
                type = "custom:apexcharts-card";
                header = {
                  show = true;
                  title = "Traffic and speedtest";
                  show_states = false;
                };
                graph_span = "3d";
                grid_options.columns = "full";
                apex_config.chart.height = 180;
                yaxis = [
                  {
                    min = 0;
                    decimals = 0;
                  }
                ];
                series =
                  let
                    traffic = id: name: color: {
                      entity = e id;
                      inherit name color;
                      type = "area";
                      opacity = 0.35;
                      stroke_width = 1;
                      group_by = {
                        func = "avg";
                        duration = "5min";
                      };
                    };
                    speedtest = id: name: color: {
                      entity = e id;
                      inherit name color;
                      type = "line";
                      curve = "stepline";
                      stroke_width = 1.5;
                    };
                  in
                  [
                    (traffic "download" "Download" "#1e88e5")
                    (traffic "upload" "Upload" "#fb8c00")
                    (speedtest "speedtest_download" "Speedtest download" "#1e88e5")
                    (speedtest "speedtest_upload" "Speedtest upload" "#fb8c00")
                  ];
              }
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "markdown";
                title = "Diagnosis";
                content = ''
                  {% if is_state('${e "diagnosis"}', 'OK') %}No problems found.{% else %}{{ state_attr('${e "diagnosis"}', 'problems') }}{% endif %}
                '';
              }
            ];
          }
          {
            type = "grid";
            cards = [
              (graph "Latency" 24 [
                [
                  "latency"
                  "Latency to internet (~10 ms normal)"
                ]
                [
                  "latency_p95"
                  "Latency spikes, p95 (< 60 ms)"
                ]
                [
                  "cmts_latency"
                  "Latency over the cable to Vodafone (~10 ms)"
                ]
                [
                  "station_latency"
                  "Latency to the router (< 5 ms)"
                ]
              ])
              (graph "Packet loss" 24 [
                [
                  "loss"
                  "Packet loss to internet (should be 0)"
                ]
                [
                  "cmts_loss"
                  "Packet loss over the cable (should be 0)"
                ]
                [
                  "station_loss"
                  "Packet loss to the router (should be 0)"
                ]
              ])
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "entities";
                title = "Cable modem";
                # good ranges in the names; per channel: Grafana "Internet (gg23)"
                entities = [
                  (e "docsis_online")
                  {
                    entity = e "unlocked";
                    name = "DOCSIS channels not locked (should be 0)";
                  }
                  {
                    entity = e "ds_snr_min";
                    name = "Downstream SNR min (≥ 33 dB)";
                  }
                  {
                    entity = e "ds_power_min";
                    name = "Downstream power min (≥ -4 dBmV)";
                  }
                  {
                    entity = e "ds_power_max";
                    name = "Downstream power max (≤ 13 dBmV)";
                  }
                  {
                    entity = e "us_power_max";
                    name = "Upstream power max (35–51 dBmV)";
                  }
                  (e "station_uptime")
                  (e "station_up")
                ];
              }
              (graph "DOCSIS levels" 168 [
                [
                  "ds_snr_min"
                  "Downstream SNR min"
                ]
                [
                  "ds_power_min"
                  "Downstream power min"
                ]
                [
                  "ds_power_max"
                  "Downstream power max"
                ]
                [
                  "us_power_max"
                  "Upstream power max"
                ]
              ])
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
    "${json "internet.yaml" package}:/config/packages/internet.yaml:ro"
    "${json "internet-dashboard.yaml" dashboard}:/config/dashboards/internet.yaml:ro"
  ];
}
