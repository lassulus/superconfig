{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  appservices = config.lass.matrix-appservices;
  appservice = appservices.bridges.telegram;
in
{
  # mautrix-telegram is the Python (Telethon) bridge and pulls in python-olm
  # → libolm 3.2.16, which nixpkgs marks insecure. The Go-based v2 bridges
  # (signal/whatsapp) avoid this via withGoolm; Python has no equivalent, so
  # secureify olm via overlay. Avoids nixpkgs.config.permittedInsecurePackages
  # which doesn't list-merge across modules.
  nixpkgs.overlays = [
    (_final: prev: {
      olm = self.lib.secureify prev.olm;
    })
  ];

  services.mautrix-telegram = {
    enable = true;
    # api_id / api_hash supplied via env (MAUTRIX_TELEGRAM_TELEGRAM_API_ID,
    # MAUTRIX_TELEGRAM_TELEGRAM_API_HASH) so they never enter the nix store
    environmentFile = config.clan.core.vars.generators.mautrix-telegram.files.env.path;
    settings = {
      homeserver = {
        address = appservices.homeserver;
        domain = "lassul.us";
      };
      appservice = {
        inherit (appservice) address port;
        hostname = "0.0.0.0";
        database = "postgres:///mautrix-telegram?host=/run/postgresql";
        id = "telegram";
        bot_username = "telegrambot";
        ephemeral_events = true;
      };
      # mautrix-telegram is the legacy Python (Telethon) bridge — config schema
      # is the pre-bridgev2 one, so everything bridge-related lives under
      # `bridge:`, not split into network/matrix/encryption like the v2 bridges.
      bridge = {
        username_template = "telegram_{userid}";
        alias_template = "telegram_{groupname}";
        displayname_template = "{displayname} (TG)";
        delivery_receipts = false;
        message_status_events = false;
        encryption = {
          allow = true;
          default = true;
          require = false;
        };
        permissions = {
          "lassul.us" = "full";
          "@lassulus:lassul.us" = "admin";
        };
      };
    };
  };

  # the registration Synapse uses (./appservices.nix); written before the
  # module's preStart so it neither generates its own nor other tokens
  systemd.services.mautrix-telegram = {
    serviceConfig.LoadCredential = [ "appservice:${appservice.tokens}" ];
    preStart = lib.mkBefore ''
      ${appservice.writeRegistration} "$CREDENTIALS_DIRECTORY/appservice" /var/lib/mautrix-telegram/telegram-registration.yaml
    '';
  };

  services.postgresql = {
    ensureDatabases = [ "mautrix-telegram" ];
    ensureUsers = [
      {
        name = "mautrix-telegram";
        ensureDBOwnership = true;
      }
    ];
  };

  # portal mappings, sessions, tokens: losing them means relogin and every
  # existing Matrix room orphaned
  lass.backup.state.mautrix-telegram.preBackup = ''
    mkdir -p /var/backup/postgresql
    ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
      mautrix-telegram | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/mautrix-telegram.sql.gz
  '';

  clan.core.vars.generators.mautrix-telegram = {
    files.env = { };
    prompts.api_id.description = "Telegram api_id from https://my.telegram.org/apps";
    prompts.api_hash.description = "Telegram api_hash from https://my.telegram.org/apps";
    script = ''
      {
        printf 'MAUTRIX_TELEGRAM_TELEGRAM_API_ID=%s\n' "$(cat "$prompts/api_id")"
        printf 'MAUTRIX_TELEGRAM_TELEGRAM_API_HASH=%s\n' "$(cat "$prompts/api_hash")"
      } > "$out/env"
    '';
  };
}
