# vmalert rules. metrics runs against VictoriaMetrics, logs (LogsQL) against
# VictoriaLogs; vmalert needs one instance per datasource type.
{ lib }:
let
  inherit (import ./default.nix) alwaysOn;

  alert = name: expr: for: summary: {
    alert = name;
    inherit expr for;
    labels.severity = "warning";
    annotations.summary = summary;
  };
in
{
  metrics.groups = [
    {
      name = "hosts";
      rules = [
        # absent_over_time keeps the host label of its selector, so one term
        # per machine yields one alert per missing machine.
        (alert "HostDown" (lib.concatMapStringsSep " or " (
          host: ''absent_over_time(host_uptime{host="${host}"}[10m])''
        ) alwaysOn) "0m" "{{ $labels.host }} sent no metrics for 10 minutes")
        (alert "DiskAlmostFull" "host_filesystem_used_ratio > 0.9" "15m"
          "{{ $labels.host }}: {{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
        )
        (alert "HighMemory" "1 - host_memory_available_bytes / host_memory_total_bytes > 0.95" "15m"
          "{{ $labels.host }} uses {{ $value | humanizePercentage }} of its memory"
        )
      ];
    }
    {
      name = "gatus";
      rules = [
        (alert "GatusEndpointDown" "gatus_results_endpoint_success == 0" "5m"
          "{{ $labels.name }} fails as seen from {{ $labels.vantage }}"
        )
      ];
    }
  ];

  logs.groups = [
    {
      name = "journal";
      type = "vlogs";
      interval = "1m";
      rules = [
        (alert "SystemdUnitFailed"
          ''_time:15m "Failed with result" | stats by (host, unit) count() as failures''
          "0m"
          "{{ $labels.unit }} failed on {{ $labels.host }}"
        )
      ];
    }
  ];
}
