# Vector on every machine: host metrics and the journal, written to every
# monitoring server (dual write). Each sink has its own disk buffer, so a
# server outage or a laptop being offline doesn't lose data.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ./default.nix) servers ports;

  # Containers have no disks of their own and lack the capabilities the
  # SMART exporter needs.
  smart = !config.boot.isContainer;

  buffer = {
    type = "disk";
    max_size = 512 * 1024 * 1024;
    when_full = "drop_newest";
  };

  sinksFor = server: {
    "metrics_${server}" = {
      type = "prometheus_remote_write";
      inputs = [
        "host_metrics"
        "revision_metric"
        "memory_pressure_metric"
      ];
      endpoint = "http://${server}.r:${toString ports.victoriametrics}/api/v1/write";
      healthcheck.enabled = false;
      inherit buffer;
    };
    "logs_${server}" = {
      type = "elasticsearch";
      inputs = [ "journal" ];
      endpoints = [ "http://${server}.r:${toString ports.victorialogs}/insert/elasticsearch/" ];
      mode = "bulk";
      api_version = "v8";
      healthcheck.enabled = false;
      query = {
        _msg_field = "message";
        _time_field = "timestamp";
        _stream_fields = "host,unit";
      };
      inherit buffer;
    };
  };
in
{
  services.prometheus.exporters.smartctl = lib.mkIf smart {
    enable = true;
    listenAddress = "127.0.0.1";
  };

  services.vector = {
    enable = true;
    journaldAccess = true;
    settings = {
      data_dir = "/var/lib/vector";

      sources.host_metrics_raw = {
        type = "host_metrics";
        collectors = [
          "cpu"
          "memory"
          "disk"
          "filesystem"
          "load"
          "network"
          "host"
        ];
        filesystem.filesystems.excludes = [
          "tmpfs"
          "devtmpfs"
          "overlay"
          "squashfs"
          "ramfs"
        ];
        scrape_interval_secs = 30;
      };
      sources.internal_metrics_raw = {
        type = "internal_metrics";
        scrape_interval_secs = 30;
      };
      sources.journald_raw.type = "journald";
      sources.smartctl_raw = lib.mkIf smart {
        type = "prometheus_scrape";
        endpoints = [
          "http://127.0.0.1:${toString config.services.prometheus.exporters.smartctl.port}/metrics"
        ];
        scrape_interval_secs = 60;
      };

      # Memory PSI: the time some task stalled on memory, as a counter in
      # seconds, so rate() over it is the stalled fraction of a window.
      sources.memory_pressure_raw = {
        type = "exec";
        mode = "scheduled";
        scheduled.exec_interval_secs = 30;
        command = [
          "${pkgs.coreutils}/bin/cat"
          "/proc/pressure/memory"
        ];
        include_stderr = false;
      };
      transforms.memory_pressure = {
        type = "remap";
        inputs = [ "memory_pressure_raw" ];
        source = ''
          fields = parse_key_value!(.message)
          if !exists(fields.some) { abort }
          . = { "seconds": to_int!(fields.total) / 1000000 }
        '';
        drop_on_abort = true;
      };
      transforms.memory_pressure_metric = {
        type = "log_to_metric";
        inputs = [ "memory_pressure" ];
        metrics = [
          {
            type = "counter";
            kind = "absolute";
            increment_by_value = true;
            field = "seconds";
            name = "host_pressure_memory_some_seconds_total";
            tags.host = config.networking.hostName;
          }
        ];
      };

      # The superconfig revision the machine runs, written by deploy and
      # autoUpgrade after a switch. Read at runtime: it is in no derivation,
      # so a new commit doesn't change every machine's closure.
      sources.revision_raw = {
        type = "exec";
        mode = "scheduled";
        scheduled.exec_interval_secs = 30;
        command = [
          pkgs.runtimeShell
          "-c"
          "cat /var/lib/superconfig-revision 2>/dev/null || echo unknown"
        ];
        include_stderr = false;
      };
      transforms.revision = {
        type = "remap";
        inputs = [ "revision_raw" ];
        source = ''
          rev = strip_whitespace(string!(.message))
          if rev == "" { rev = "unknown" }
          . = {
            "value": 1,
            "revision": rev,
            "revision_short": replace(rev, r'^([0-9a-f]{7})[0-9a-f]{33}', "$1"),
          }
        '';
      };
      transforms.revision_metric = {
        type = "log_to_metric";
        inputs = [ "revision" ];
        metrics = [
          {
            type = "gauge";
            field = "value";
            name = "nixos_system_info";
            tags = {
              host = config.networking.hostName;
              revision = "{{revision}}";
              revision_short = "{{revision_short}}";
            };
          }
        ];
      };

      # The NixOS hostname as host label on every metric, the same value the
      # journal events get below (alerts and dashboards match on it).
      transforms.host_metrics = {
        type = "remap";
        inputs = [
          "host_metrics_raw"
          "internal_metrics_raw"
        ]
        ++ lib.optional smart "smartctl_raw";
        source = ''
          .tags.host = "${config.networking.hostName}"
        '';
      };

      # Keep only what we query on: drop debug messages and the many
      # journald bookkeeping fields. unit prefers UNIT/USER_UNIT, which
      # systemd sets on its own messages about a unit ("Failed with result"),
      # so those land in the stream of the unit they are about.
      transforms.journal = {
        type = "remap";
        inputs = [ "journald_raw" ];
        source = ''
          if .PRIORITY == "7" { abort }
          . = {
            "timestamp": .timestamp,
            "message": .message,
            "host": "${config.networking.hostName}",
            "unit": .UNIT || .USER_UNIT || ._SYSTEMD_USER_UNIT || ._SYSTEMD_UNIT || .SYSLOG_IDENTIFIER || "unknown",
            "priority": .PRIORITY,
            "identifier": .SYSLOG_IDENTIFIER,
          }
        '';
        drop_on_abort = true;
      };

      sinks = lib.mergeAttrsList (map sinksFor servers);
    };
  };
}
