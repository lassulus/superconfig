# Why is the gg23 internet slow? Runs on acheron, the gg23 router, whose WAN
# (et0) sits behind the Vodafone Station (ARRIS TG3442DE cable modem, LAN
# 192.168.0.1). Exports, via the Vector agent (configs/monitoring/agent.nix)
# into VictoriaMetrics on the monitoring servers:
# - the Station's DOCSIS channel power/SNR/lock and its status, scraped from
#   its web UI (tools/vodafone-station-exporter)
# - latency and loss to the Station, the CMTS and the internet
#   (smokeping_prober)
# - hourly speedtests (./internet-speedtest.nix)
# WAN throughput is in the host metrics already (et0 on acheron). Grafana
# shows it as "Internet", Home Assistant as the "Internet" dashboard
# (./internet-hass.nix).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  smokeping = config.services.prometheus.exporters.smokeping;

  # target label -> address. `cmts` is the first hop behind the cable modem
  # (91.64.96.254 = gateway of the WAN 91.64.96.0/24, from mtr). If Vodafone
  # moves us to another subnet it shows as 100% loss here: update it then.
  targets = {
    station = "192.168.0.1";
    cmts = "91.64.96.254";
    cloudflare = "1.1.1.1";
    google = "8.8.8.8";
    cloudflare6 = "2606:4700:4700::1111";
    google6 = "2001:4860:4860::8888";
  };
in
{
  imports = [
    ./internet-hass.nix
    ./internet-speedtest.nix
  ];

  lass.ports = {
    "9764" = "vodafone-station-exporter";
    ${toString smokeping.port} = "smokeping-exporter";
  };

  clan.core.vars.generators.vodafone-station.prompts.password = {
    description = "Vodafone Station (192.168.0.1) web UI admin password, passage admin/gg23/vodafone-router/pass";
    type = "hidden";
    persist = true;
  };

  systemd.services.vodafone-station-exporter = {
    description = "Prometheus exporter for the Vodafone Station";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.vodafone-station-exporter)
        "--listen"
        "127.0.0.1:${toString config.lass.servicePorts.vodafone-station-exporter}"
        "--password-file"
        "%d/password"
      ];
      LoadCredential = [
        "password:${config.clan.core.vars.generators.vodafone-station.files.password.path}"
      ];
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  services.prometheus.exporters.smokeping = {
    enable = true;
    listenAddress = "127.0.0.1";
    hosts = lib.attrValues targets;
  };

  monitoring.extraMetrics = [ "internet_metrics" ];

  services.vector.settings = {
    # The Station is slow: one login + three pages take ~6s. Every scrape
    # logs in and out again, so keep the interval relaxed.
    sources.vodafone_station_raw = {
      type = "prometheus_scrape";
      endpoints = [
        "http://127.0.0.1:${toString config.lass.servicePorts.vodafone-station-exporter}/metrics"
      ];
      scrape_interval_secs = 60;
      scrape_timeout_secs = 45;
    };
    sources.smokeping_raw = {
      type = "prometheus_scrape";
      endpoints = [
        "http://127.0.0.1:${toString smokeping.port}${smokeping.telemetryPath}"
      ];
      scrape_interval_secs = 30;
    };
    # smokeping_prober labels the probed address `host`, which is our
    # machine label everywhere else: move it to `target` (plus the name from
    # `targets`), then set host like the agent does.
    transforms.internet_metrics = {
      type = "remap";
      inputs = [
        "vodafone_station_raw"
        "smokeping_raw"
      ];
      source = ''
        names = ${builtins.toJSON (lib.mapAttrs' (n: v: lib.nameValuePair v n) targets)}
        if exists(.tags.host) {
          .tags.target = del(.tags.host)
          .tags.target_name = get(names, [.tags.target]) ?? .tags.target
        }
        .tags.host = "${config.networking.hostName}"
      '';
    };
  };
}
