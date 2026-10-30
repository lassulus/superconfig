# The mautrix bridges. They run at home, Synapse stays on neoprism
# (./synapse.nix); see ./appservices.nix for why and how they're wired.
{ config, lib, ... }:
let
  appservices = config.lass.matrix-appservices;
  ports = lib.mapAttrsToList (_: bridge: toString bridge.port) appservices.bridges;
in
{
  imports = [
    ./appservices.nix
    ./mautrix-discord.nix
    ./mautrix-signal.nix
    ./mautrix-telegram.nix
    ./mautrix-whatsapp.nix
  ];

  services.postgresql.enable = true;
  # the modules only order the bridges after a local Synapse, which used to
  # bring postgres up first; without it they race the postgres socket
  systemd.services = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "mautrix-${name}" {
      after = [ "postgresql.target" ];
      requires = [ "postgresql.target" ];
    }
  ) appservices.bridges;

  # Synapse pushes events to the bridges over retiolum, accept only neoprism
  networking.firewall.extraInputRules = ''
    iifname "retiolum" ip saddr ${appservices.synapseIp4} tcp dport { ${lib.concatStringsSep ", " ports} } accept
  '';
}
