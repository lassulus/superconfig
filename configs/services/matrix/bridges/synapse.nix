# Synapse side of the mautrix bridges, which run on styx (./default.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.lass.matrix-appservices) bridges;
  registration = name: "/var/lib/matrix-synapse/${name}-registration.yaml";
in
{
  imports = [ ./appservices.nix ];

  services.matrix-synapse.settings.app_service_config_files = map registration (
    lib.attrNames bridges
  );

  systemd.services.matrix-synapse.serviceConfig.ExecStartPre = lib.mapAttrsToList (
    name: bridge:
    "+${pkgs.writeShellScript "write-${name}-registration-for-synapse" ''
      ${bridge.writeRegistration} ${bridge.tokens} ${registration name}
      chown matrix-synapse:matrix-synapse ${registration name}
    ''}"
  ) bridges;
}
