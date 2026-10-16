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
        (alert "MemoryPressure" "rate(host_pressure_memory_some_seconds_total[10m]) > 0.1" "5m"
          "{{ $labels.host }}: tasks stalled on memory {{ $value | humanizePercentage }} of the time"
        )
        (alert "OOMKill" "increase(host_memory_oom_kill_events_total[10m]) > 0" "0m"
          "{{ $labels.host }}: {{ $value }} processes OOM-killed in the last 10 minutes"
        )
        # NVMe drives set critical_warning bit 0x04 (and so fail smart_status)
        # once they exceed their rated endurance; their wear is covered by
        # NvmeSpareLow instead. 251 masks out bit 0x04.
        (alert "SmartFailed"
          ''smartctl_device_smart_status == 0 unless on (host, device) smartctl_device{protocol="NVMe"}''
          "5m"
          "{{ $labels.host }}: {{ $labels.device }} fails its SMART health check"
        )
        (alert "NvmeCriticalWarning" "bitmap_and(smartctl_device_critical_warning, 251) != 0" "5m"
          "{{ $labels.host }}: {{ $labels.device }} reports critical warning {{ $value }}"
        )
        (alert "NvmeMediaErrors" "increase(smartctl_device_media_errors[1h]) > 0" "0m"
          "{{ $labels.host }}: {{ $labels.device }} had {{ $value }} new media errors in the last hour"
        )
        (alert "NvmeSpareLow" "smartctl_device_available_spare < smartctl_device_available_spare_threshold"
          "5m"
          "{{ $labels.host }}: {{ $labels.device }} has only {{ $value }}% spare left"
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
        # systemd logs "<unit>: Failed with result '<result>'."; the anchored
        # regexp skips lines merely quoting the phrase, such as VictoriaLogs
        # warnings that echo a rejected query.
        (alert "SystemdUnitFailed"
          ''_time:15m "Failed with result" _msg:~"^[^ ]+: Failed with result '" | stats by (host, unit) count() as failures''
          "0m"
          "{{ $labels.unit }} failed on {{ $labels.host }}"
        )
      ];
    }
  ];
}
