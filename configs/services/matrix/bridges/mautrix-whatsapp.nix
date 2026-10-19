{ config, pkgs, ... }:
{
  services.mautrix-whatsapp = {
    enable = true;
    registerToSynapse = true;
    # use pure-Go olm implementation to avoid the insecure libolm dependency
    package = pkgs.mautrix-whatsapp.override { withGoolm = true; };
    settings = {
      homeserver = {
        address = "http://[::1]:8008";
        domain = "lassul.us";
      };
      appservice = {
        address = "http://127.0.0.1:29318";
        hostname = "127.0.0.1";
        port = 29318;
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
        allow = false;
        default = false;
        require = false;
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

  # let synapse read the appservice registration file written by the bridge
  users.users.matrix-synapse.extraGroups = [ "mautrix-whatsapp" ];

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
