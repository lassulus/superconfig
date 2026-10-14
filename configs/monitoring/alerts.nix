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
        # Network mounts (and their autofs placeholders) are reported by
        # every machine that mounts them; the agent drops tmpfs & co.
        # neoprism's /var/download is always above 90%, see DownloadSpace*.
        (alert "DiskAlmostFull"
          ''host_filesystem_used_ratio{filesystem!~"cifs|smb3|nfs|nfs4|autofs|fuse.sshfs"} > 0.9 unless on (host, mountpoint) host_filesystem_used_ratio{host="neoprism",mountpoint="/var/download"}''
          "15m"
          "{{ $labels.host }}: {{ $labels.mountpoint }} is {{ $value | humanizePercentage }} full"
        )
        (alert "DownloadSpaceLow"
          ''host_filesystem_free_bytes{host="neoprism",mountpoint="/var/download"} < 200e9''
          "15m"
          "{{ $labels.host }}: {{ $labels.mountpoint }} has only {{ $value | humanize }}B free"
        )
        (
          alert "DownloadSpaceCritical"
            ''host_filesystem_free_bytes{host="neoprism",mountpoint="/var/download"} < 100e9''
            "15m"
            "{{ $labels.host }}: {{ $labels.mountpoint }} has only {{ $value | humanize }}B free"
          // {
            labels.severity = "critical";
          }
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
