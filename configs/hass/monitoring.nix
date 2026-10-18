# Home Assistant states into the monitoring (configs/monitoring): HA's
# prometheus integration serves every entity on /api/prometheus, the Vector
# agent scrapes it with a long-lived access token and writes it to
# VictoriaMetrics like the host metrics (metric names homeassistant_*).
{ config, pkgs, ... }:
{
  # Mounted as a package; configuration.yaml in the volume loads
  # /config/packages (homeassistant: packages: !include_dir_named packages).
  virtualisation.oci-containers.containers.homeassistant.volumes = [
    "${
      pkgs.writeText "prometheus.yaml" (builtins.toJSON { prometheus = { }; })
    }:/config/packages/prometheus.yaml:ro"
  ];

  # Create in HA: profile -> security -> long-lived access tokens.
  clan.core.vars.generators.hass-prometheus.prompts.token = {
    description = "Home Assistant long-lived access token for the Vector scrape of /api/prometheus";
    type = "hidden";
    persist = true;
  };

  systemd.services.vector.serviceConfig.LoadCredential = [
    "hass-token:${config.clan.core.vars.generators.hass-prometheus.files.token.path}"
  ];

  monitoring.extraMetrics = [ "hass_metrics" ];

  services.vector.settings = {
    secret.credentials = {
      type = "directory";
      path = "/run/credentials/vector.service";
    };
    sources.hass_raw = {
      type = "prometheus_scrape";
      endpoints = [ "http://127.0.0.1:8123/api/prometheus" ];
      auth = {
        strategy = "bearer";
        token = "SECRET[credentials.hass-token]";
      };
      scrape_interval_secs = 60;
      scrape_timeout_secs = 30;
    };
    transforms.hass_metrics = {
      type = "remap";
      inputs = [ "hass_raw" ];
      source = ''
        .tags.host = "${config.networking.hostName}"
      '';
    };
  };
}
