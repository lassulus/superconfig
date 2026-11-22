# Synapse side of the mautrix bridges, which run on styx (./default.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  appservices = config.lass.matrix-appservices;
  registrations = appservices.bridges // {
    inherit (appservices) doublepuppet;
  };
  registration = name: "/var/lib/matrix-synapse/${name}-registration.yaml";
in
{
  imports = [ ./appservices.nix ];

  services.matrix-synapse.settings.app_service_config_files = map registration (
    lib.attrNames registrations
  );

  systemd.services.matrix-synapse.serviceConfig.ExecStartPre = lib.mapAttrsToList (
    name: appservice:
    "+${pkgs.writeShellScript "write-${name}-registration-for-synapse" ''
      ${appservice.writeRegistration} ${appservice.tokens} ${registration name}
      chown matrix-synapse:matrix-synapse ${registration name}
    ''}"
  ) registrations;
}
