# One monitoring server (styx, coaxmetal): VictoriaMetrics and VictoriaLogs
# receive from the Vector agents, vmalert evaluates alerts/checks into the
# Alertmanager cluster formed by all servers, which posts to Matrix. Gatus
# runs the functional checks, Grafana shows it all. Everything listens on
# retiolum only.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  inherit (import ./default.nix) servers ports;
  alerts = import ./alerts.nix { inherit lib; };

  name = config.networking.hostName;
  peers = lib.remove name servers;
  # Alertmanager gossips the address it advertises, so it must be the
  # retiolum one, not whatever private address it would pick on its own.
  retiolumIp = self.inputs.kartei.hosts.${name}.nets.retiolum.ip4.addr;

  receiverConfig = pkgs.writeText "matrix-alertmanager-receiver.json" (
    builtins.toJSON {
      http = {
        address = "127.0.0.1";
        port = ports.matrix-receiver;
      };
      # ${...} is substituted by the receiver from its environment
      # (monitoring-matrix vars).
      matrix = {
        homeserver-url = "https://matrix.lassul.us";
        user-id = "\${MATRIX_USER_ID}";
        access-token = "\${MATRIX_ACCESS_TOKEN}";
        room-mapping.alerts = "\${MATRIX_ROOM_ID}";
      };
      templating.firing-template = ''
        {{ if eq .Alert.Labels.severity "critical" }}🚨 {{ end }}<strong>{{ .Alert.Status | ToUpper }}</strong> {{ .Alert.Labels.alertname }}:
        {{ .Alert.Annotations.summary }}
      '';
    }
  );

  grafanaVars = config.clan.core.vars.generators.monitoring-grafana.files;
in
{
  services.victoriametrics = {
    enable = true;
    listenAddress = ":${toString ports.victoriametrics}";
    retentionPeriod = "90d";
    # Merge samples of the same series at the same timestamp, so re-imported
    # Gadgetbridge exports don't duplicate. 1ms leaves scraped data alone.
    extraOptions = [ "-dedup.minScrapeInterval=1ms" ];
    # Gatus results; the vantage label tells which server saw a failure.
    prometheusConfig.scrape_configs = [
      {
        job_name = "gatus";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString ports.gatus}" ];
            labels.vantage = name;
          }
        ];
      }
    ];
  };

  services.victorialogs = {
    enable = true;
    listenAddress = ":${toString ports.victorialogs}";
    extraOptions = [ "-retentionPeriod=30d" ];
  };

  services.vmalert.instances = {
    "" = {
      enable = true;
      rules = alerts.metrics;
      settings = {
        "datasource.url" = "http://127.0.0.1:${toString ports.victoriametrics}";
        "notifier.url" = map (s: "http://${s}.r:${toString ports.alertmanager}") servers;
        "httpListenAddr" = ":${toString ports.vmalert}";
        "external.url" = "http://${name}.r:${toString ports.vmalert}";
      };
    };
    logs = {
      enable = true;
      rules = alerts.logs;
      settings = {
        "datasource.url" = "http://127.0.0.1:${toString ports.victorialogs}";
        "notifier.url" = map (s: "http://${s}.r:${toString ports.alertmanager}") servers;
        "httpListenAddr" = "127.0.0.1:${toString ports.vmalert-logs}";
        "rule.defaultRuleType" = "vlogs";
      };
    };
  };

  services.prometheus.alertmanager = {
    enable = true;
    port = ports.alertmanager;
    webExternalUrl = "http://${name}.r:${toString ports.alertmanager}";
    clusterPeers = map (p: "${p}.r") peers;
    extraFlags = [
      "--cluster.listen-address=[::]:${toString ports.alertmanager-cluster}"
      "--cluster.advertise-address=${retiolumIp}:${toString ports.alertmanager-cluster}"
    ];
    configuration = {
      route = {
        receiver = "matrix";
        group_by = [
          "alertname"
          "host"
        ];
        repeat_interval = "12h";
      };
      receivers = [
        {
          name = "matrix";
          webhook_configs = [
            {
              url = "http://127.0.0.1:${toString ports.matrix-receiver}/alerts/alerts";
              send_resolved = true;
            }
          ];
        }
      ];
    };
  };

  # No NixOS module for it upstream. It exits when the homeserver is
  # unreachable at startup, so keep retrying instead of hitting the start
  # limit (e.g. while neoprism reboots).
  systemd.services.matrix-alertmanager-receiver = {
    description = "Forward Alertmanager alerts to Matrix";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.matrix-alertmanager-receiver} --config-path ${receiverConfig}";
      EnvironmentFile = config.clan.core.vars.generators.monitoring-matrix.files.env.path;
      DynamicUser = true;
      Restart = "always";
      RestartSec = 30;
    };
  };

  # Shared, so both servers post as the same bot into the same room.
  # Declared identically on every server, as clan requires for shared vars.
  clan.core.vars.generators.monitoring-matrix = {
    share = true;
    files.env = { };
    prompts.user-id.description = "Matrix user id of the alert bot, e.g. @alerts:lassul.us";
    prompts.access-token = {
      description = "Access token of the alert bot";
      type = "hidden";
    };
    prompts.room-id.description = "Matrix room id for alerts (!…:lassul.us); invite the bot first";
    script = ''
      {
        printf 'MATRIX_USER_ID=%s\n' "$(cat "$prompts/user-id")"
        printf 'MATRIX_ACCESS_TOKEN=%s\n' "$(cat "$prompts/access-token")"
        printf 'MATRIX_ROOM_ID=%s\n' "$(cat "$prompts/room-id")"
      } > "$out/env"
    '';
  };

  services.gatus = {
    enable = true;
    settings = import ./checks.nix // {
      web.port = ports.gatus;
      metrics = true;
    };
  };

  services.grafana = {
    enable = true;
    declarativePlugins = [
      pkgs.grafanaPlugins.victoriametrics-logs-datasource
      pkgs.grafanaPlugins.victoriametrics-metrics-datasource
    ];
    settings = {
      server = {
        http_addr = "";
        http_port = ports.grafana;
      };
      security = {
        admin_password = "$__file{${grafanaVars.admin-password.path}}";
        secret_key = "$__file{${grafanaVars.secret-key.path}}";
      };
      "auth.anonymous" = {
        enabled = true;
        org_role = "Viewer";
      };
      analytics.reporting_enabled = false;
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "VictoriaMetrics";
          uid = "victoriametrics";
          type = "victoriametrics-metrics-datasource";
          url = "http://127.0.0.1:${toString ports.victoriametrics}";
          isDefault = true;
        }
        {
          name = "VictoriaLogs";
          uid = "victorialogs";
          type = "victoriametrics-logs-datasource";
          url = "http://127.0.0.1:${toString ports.victorialogs}";
        }
      ];
      dashboards.settings.providers = [
        {
          name = "monitoring";
          options.path = ./dashboards;
        }
      ];
    };
  };

  clan.core.vars.generators.monitoring-grafana = {
    files.admin-password.owner = "grafana";
    files.secret-key.owner = "grafana";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/admin-password"
      openssl rand -hex 32 | tr -d '\n' > "$out/secret-key"
    '';
  };

  networking.firewall.interfaces.retiolum = {
    allowedTCPPorts = with ports; [
      victoriametrics
      victorialogs
      vmalert
      alertmanager
      alertmanager-cluster
      gatus
      grafana
    ];
    allowedUDPPorts = [ ports.alertmanager-cluster ];
  };
}
