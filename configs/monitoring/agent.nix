# Vector on every machine: host metrics and the journal, written to every
# monitoring server (dual write). Each sink has its own disk buffer, so a
# server outage or a laptop being offline doesn't lose data.
{ config, lib, ... }:
let
  inherit (import ./default.nix) servers ports;

  buffer = {
    type = "disk";
    max_size = 512 * 1024 * 1024;
    when_full = "drop_newest";
  };

  sinksFor = server: {
    "metrics_${server}" = {
      type = "prometheus_remote_write";
      inputs = [ "host_metrics" ];
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

      # The NixOS hostname as host label on every metric, the same value the
      # journal events get below (alerts and dashboards match on it).
      transforms.host_metrics = {
        type = "remap";
        inputs = [
          "host_metrics_raw"
          "internal_metrics_raw"
        ];
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
