{ config, pkgs, ... }:
let
  appservices = config.lass.matrix-appservices;
  appservice = appservices.bridges.discord;
in
{
  services.mautrix-discord = {
    enable = true;
    # AS_TOKEN / HS_TOKEN of the registration Synapse uses (./appservices.nix);
    # the module writes them into its own registration on every start
    environmentFile = appservice.tokens;
    settings = {
      homeserver = {
        address = appservices.homeserver;
        domain = "lassul.us";
      };
      # `settings.{homeserver,appservice,bridge,logging}` use `types.attrs` with
      # full defaults, so this is a shallow merge — set keys override the
      # default's same-level keys, but nested subtrees we redefine (database,
      # bot, encryption, permissions) replace the default's subtree wholesale.
      # The bridge fills keys missing from them in from its example config.
      appservice = {
        inherit (appservice) address port;
        hostname = "0.0.0.0";
        as_token = "$AS_TOKEN";
        hs_token = "$HS_TOKEN";
        database = {
          type = "postgres";
          uri = "postgres:///mautrix-discord?host=/run/postgresql";
        };
        id = "discord";
        bot = {
          username = "discordbot";
          displayname = "Discord bridge bot";
          avatar = "mxc://maunium.net/nIdEykemnwdisvHbpxflpDlC";
        };
        ephemeral_events = true;
      };
      bridge = {
        username_template = "discord_{{.}}";
        displayname_template = "{{if .Webhook}}Webhook{{else}}{{or .GlobalName .Username}}{{if .Bot}} (bot){{end}}{{end}} (D)";
        delivery_receipts = false;
        message_status_events = false;
        encryption = {
          allow = true;
          default = true;
          require = false;
        };
        permissions = {
          "lassul.us" = "user";
          "@lassulus:lassul.us" = "admin";
        };
      };
    };
  };

  services.postgresql = {
    ensureDatabases = [ "mautrix-discord" ];
    ensureUsers = [
      {
        name = "mautrix-discord";
        ensureDBOwnership = true;
      }
    ];
  };

  # portal mappings, sessions, tokens: losing them means relogin and every
  # existing Matrix room orphaned
  lass.backup.state.mautrix-discord.preBackup = ''
    mkdir -p /var/backup/postgresql
    ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
      mautrix-discord | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/mautrix-discord.sql.gz
  '';
}
