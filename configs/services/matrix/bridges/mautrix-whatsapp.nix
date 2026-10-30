{
  config,
  lib,
  pkgs,
  ...
}:
let
  appservices = config.lass.matrix-appservices;
  appservice = appservices.bridges.whatsapp;
in
{
  services.mautrix-whatsapp = {
    enable = true;
    # use pure-Go olm implementation to avoid the insecure libolm dependency
    package = pkgs.mautrix-whatsapp.override { withGoolm = true; };
    environmentFile = config.clan.core.vars.generators.mautrix-whatsapp.files.env.path;
    settings = {
      homeserver = {
        address = appservices.homeserver;
        domain = "lassul.us";
      };
      appservice = {
        inherit (appservice) address port;
        hostname = "0.0.0.0";
        username_template = "whatsapp_{{.}}";
      };
      database = {
        type = "postgres";
        uri = "postgres:///mautrix-whatsapp?host=/run/postgresql";
      };
      # mautrix-whatsapp v2 (bridgev2 framework) splits config into multiple
      # top-level sections: `network:` for WA-specific behavior, `matrix:` for
      # Matrix-side behavior, `encryption:` for E2EE, `bridge:` only for
      # generic bridge framework options.
      network = {
        displayname_template = "{{or .FullName .PushName .JID}} (WA)";
        history_sync = {
          request_full_sync = true;
        };
      };
      matrix = {
        # positive per-message confirmation: sends went undelivered silently
        # for over a week in 2026-06 with no error surfaced to the client
        delivery_receipts = true;
        message_status_events = true;
      };
      encryption = {
        allow = true;
        default = true;
        require = false;
        pickle_key = "$ENCRYPTION_PICKLE_KEY";
      };
      bridge = {
        personal_filtering_spaces = true;
        permissions = {
          "lassul.us" = "user";
          "@lassulus:lassul.us" = "admin";
        };
      };
      logging = {
        min_level = "info";
        writers = [
          {
            type = "stdout";
            format = "pretty-colored";
          }
        ];
      };
    };
  };

  # the registration Synapse uses (./appservices.nix); written before the
  # module's preStart so it neither generates its own nor other tokens
  systemd.services.mautrix-whatsapp = {
    serviceConfig.LoadCredential = [ "appservice:${appservice.tokens}" ];
    preStart = lib.mkBefore ''
      ${appservice.writeRegistration} "$CREDENTIALS_DIRECTORY/appservice" /var/lib/mautrix-whatsapp/whatsapp-registration.yaml
    '';
  };

  # pickle_key encrypts the bridge's olm account in its database: it has to
  # stay the same for the life of that crypto store
  clan.core.vars.generators.mautrix-whatsapp = {
    files.env = { };
    runtimeInputs = [ pkgs.pwgen ];
    script = ''
      printf 'ENCRYPTION_PICKLE_KEY=%s\n' "$(pwgen -s 64 1)" > "$out"/env
    '';
  };

  services.postgresql = {
    ensureDatabases = [ "mautrix-whatsapp" ];
    ensureUsers = [
      {
        name = "mautrix-whatsapp";
        ensureDBOwnership = true;
      }
    ];
  };

  # portal mappings, sessions, tokens: losing them means relogin and every
  # existing Matrix room orphaned
  lass.backup.state.mautrix-whatsapp.preBackup = ''
    mkdir -p /var/backup/postgresql
    ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
      mautrix-whatsapp | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/mautrix-whatsapp.sql.gz
  '';
}
