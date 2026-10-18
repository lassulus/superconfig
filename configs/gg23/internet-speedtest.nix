# Hourly speedtest from acheron, replacing Home Assistant's SpeedTest
# integration: speedtest.net geolocates our Vodafone IP near Sicily, so HA
# only offered servers in Italy/Tunisia/Algeria, and its single-threaded
# Python client collapsed on their 500+ ms latency (42 Mbit/s on a 1000/50
# line). speedtest-go runs parallel connections against a German server.
#
# Each run appends one JSON line to results.jsonl (also the history); the
# Vector agent tails it into VictoriaMetrics. A run moves ~1.4 GB and
# saturates the line for ~30 s, hence hourly and not more often.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dir = "/var/lib/speedtest";
in
{
  # Static user: a DynamicUser's state lives under /var/lib/private (0700),
  # where Vector (itself a DynamicUser) can't read it.
  users.users.speedtest = {
    isSystemUser = true;
    group = "speedtest";
  };
  users.groups.speedtest = { };

  systemd.services.speedtest = {
    description = "Speedtest against a German speedtest.net server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "speedtest";
      Group = "speedtest";
      StateDirectory = "speedtest";
      StateDirectoryMode = "0755";
      UMask = "0022";
      TimeoutStartSec = "5min";
    };
    script = ''
      ${lib.getExe pkgs.speedtest-go} --jsonl --filter-cc DE >> ${dir}/results.jsonl
    '';
  };

  systemd.timers.speedtest = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "10min";
    };
  };

  monitoring.extraMetrics = [ "speedtest_metrics" ];

  services.vector.settings = {
    sources.speedtest_raw = {
      type = "file";
      include = [ "${dir}/results.jsonl" ];
    };
    # speedtest-go: speeds in bytes/s, latencies in ns
    transforms.speedtest = {
      type = "remap";
      inputs = [ "speedtest_raw" ];
      source = ''
        r = parse_json!(.message)
        s = object!(r.server)
        . = {
          "download": to_float!(s.dl_speed) * 8,
          "upload": to_float!(s.ul_speed) * 8,
          "latency": to_float!(s.latency) / 1000000000,
          "jitter": to_float!(s.jitter) / 1000000000,
          "server": string!(s.sponsor) + " " + string!(s.name),
          "server_id": string!(s.id),
        }
      '';
      drop_on_error = true;
    };
    transforms.speedtest_metrics = {
      type = "log_to_metric";
      inputs = [ "speedtest" ];
      metrics =
        map
          (m: {
            type = "gauge";
            field = m.field;
            name = "speedtest_${m.name}";
            tags = {
              host = config.networking.hostName;
              server = "{{server}}";
              server_id = "{{server_id}}";
            };
          })
          [
            {
              field = "download";
              name = "download_bits_per_second";
            }
            {
              field = "upload";
              name = "upload_bits_per_second";
            }
            {
              field = "latency";
              name = "latency_seconds";
            }
            {
              field = "jitter";
              name = "jitter_seconds";
            }
          ];
    };
  };
}
