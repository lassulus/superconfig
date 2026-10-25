# WebDAV for Gadgetbridge's hourly database export from the phone (via
# DAVx5), at https://health.lassul.us/dav/ (proxied by neoprism,
# configs/health-dav-proxy.nix). Each new export is imported into
# VictoriaMetrics.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  inherit (import ./monitoring/default.nix) ports;
  port = 8097;
  dir = "/var/lib/health-dav";
in
{
  services.webdav = {
    enable = true;
    settings = {
      address = "0.0.0.0";
      inherit port;
      prefix = "/dav";
      behindProxy = true;
      directory = dir;
      permissions = "CRUD";
      users = [
        {
          username = "gadgetbridge";
          password = "{env}HEALTH_DAV_PASSWORD";
        }
      ];
    };
    environmentFile = config.clan.core.vars.generators.health-dav.files.env.path;
  };
  systemd.services.webdav.serviceConfig = {
    StateDirectory = "health-dav";
    StateDirectoryMode = "0750";
  };

  clan.core.vars.generators.health-dav = {
    files.password = { };
    files.env = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/password"
      printf 'HEALTH_DAV_PASSWORD=%s\n' "$(cat "$out/password")" > "$out/env"
    '';
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];

  systemd.services.gadgetbridge-import = {
    description = "Import the Gadgetbridge export into VictoriaMetrics";
    startAt = "hourly";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs [
        (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.gadgetbridge-import)
        "--url"
        "http://127.0.0.1:${toString ports.victoriametrics}"
        "--state-dir"
        "%S/gadgetbridge-import"
        dir
      ];
      DynamicUser = true;
      SupplementaryGroups = [ config.services.webdav.group ];
      StateDirectory = "gadgetbridge-import";
    };
  };
  systemd.paths.gadgetbridge-import = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = dir;
  };
}
