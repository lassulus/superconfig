# Wiring between Synapse on neoprism (./synapse.nix) and the mautrix bridges
# on styx (./default.nix). A bridge holds the plaintext of every bridged
# message plus the network sessions (Signal/WhatsApp/Telegram keys), so the
# bridges run at home and encrypt the Matrix side; the Hetzner box only
# stores ciphertext.
#
# Imported on both machines: the appservice tokens are shared clan vars (a
# shared generator has to be declared identically everywhere) and both sides
# render the same registration from them.
{
  self,
  lib,
  pkgs,
  config,
  ...
}:
let
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  bridgeHost = kartei.own.styx;
  synapseHost = kartei.own.neoprism;

  yaml = pkgs.formats.yaml { };
  user = regex: {
    inherit regex;
    exclusive = true;
  };

  # sender_localpart and namespaces as the bridges generated them originally;
  # the sender_localpart is the appservice's own Synapse user
  registrations = {
    signal = {
      port = 29328;
      sender_localpart = "2z1jLRNgjAEW9XUhGpVRl0TeTY8yLoIb";
      namespaces.users = [
        (user "^@signalbot:lassul\\.us$")
        (user "^@signal_.*:lassul\\.us$")
      ];
      receive_ephemeral = true;
    };
    whatsapp = {
      port = 29318;
      sender_localpart = "IF5MmIDD0sVuRhxoTjVUDGQ6jb5XIyex";
      namespaces.users = [
        (user "^@whatsappbot:lassul\\.us$")
        (user "^@whatsapp_.*:lassul\\.us$")
      ];
      receive_ephemeral = true;
    };
    discord = {
      port = 29334;
      sender_localpart = "UvgOm6Hz1UU7K2s1Jky9p02J6Bxgo0BN";
      namespaces.users = [
        (user "^@discordbot:lassul\\.us$")
        (user "^@discord_.*:lassul\\.us$")
      ];
      push_ephemeral = true;
    };
    telegram = {
      port = 29317;
      sender_localpart = "wFsS_o3tYI6KPHPq4YyKvvnLaqsjoZt_PwEM8Z7qjSHKb7_Bqt3LVE8pUTKSgIbe";
      namespaces = {
        users = [
          (user "@telegram_.*:lassul\\.us")
          (user "@telegrambot:lassul\\.us")
        ];
        aliases = [ (user "\\#telegram_.*:lassul\\.us") ];
      };
      receive_ephemeral = true;
    };
  };

  generator = name: "mautrix-${name}-appservice";

  bridge =
    name:
    { port, ... }@registration:
    let
      address = "http://${bridgeHost.ip4}:${toString port}";
      template = yaml.generate "${name}-registration.yaml" (
        removeAttrs registration [ "port" ]
        // {
          id = name;
          url = address;
          as_token = "$AS_TOKEN";
          hs_token = "$HS_TOKEN";
          rate_limited = false;
          "de.sorunome.msc2409.push_ephemeral" = true;
        }
      );
    in
    {
      inherit port address;
      # env file with AS_TOKEN and HS_TOKEN
      tokens = config.clan.core.vars.generators.${generator name}.files.env.path;
      # writeRegistration <tokens env file> <destination>
      writeRegistration = pkgs.writeShellScript "write-${name}-registration" ''
        set -eu
        set -a
        . "$1"
        set +a
        umask 027
        # only the tokens (GNU envsubst's SHELL-FORMAT): the regexes contain `$`
        ${pkgs.gettext}/bin/envsubst '$AS_TOKEN $HS_TOKEN' < ${template} > "$2"
      '';
    };
in
{
  options.lass.matrix-appservices = lib.mkOption {
    type = lib.types.attrs;
    readOnly = true;
    description = "Addresses and registrations shared by Synapse and the mautrix bridges.";
  };

  config = {
    lass.matrix-appservices = {
      # Synapse listens on neoprism's retiolum address (../default.nix)
      homeserver = "http://[${synapseHost.ip6}]:8008";
      synapseIp4 = synapseHost.ip4;
      bridges = lib.mapAttrs bridge registrations;
    };

    clan.core.vars.generators = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (generator name) {
        share = true;
        files.env = { };
        runtimeInputs = [ pkgs.pwgen ];
        script = ''
          printf 'AS_TOKEN=%s\nHS_TOKEN=%s\n' "$(pwgen -s 64 1)" "$(pwgen -s 64 1)" > "$out"/env
        '';
      }
    ) registrations;
  };
}
