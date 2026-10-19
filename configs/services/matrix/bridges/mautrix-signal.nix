{ config, pkgs, ... }:
{
  services.mautrix-signal = {
    enable = true;
    registerToSynapse = true;
    # use pure-Go olm implementation to avoid the insecure libolm dependency
    package = pkgs.mautrix-signal.override { withGoolm = true; };
    settings = {
      homeserver = {
        address = "http://[::1]:8008";
        domain = "lassul.us";
      };
      appservice = {
        address = "http://127.0.0.1:29328";
        hostname = "127.0.0.1";
        port = 29328;
        username_template = "signal_{{.}}";
      };
      database = {
        type = "postgres";
        uri = "postgres:///mautrix-signal?host=/run/postgresql";
      };
      # mautrix-signal v2 (bridgev2 framework) splits config into multiple
      # top-level sections; see mautrix-whatsapp.nix for explanation.
      network = {
        displayname_template = "{{or .ProfileName .PhoneNumber \"Unknown user\"}} (S)";
      };
      matrix = {
        delivery_receipts = false;
        message_status_events = false;
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
  users.users.matrix-synapse.extraGroups = [ "mautrix-signal" ];

  services.postgresql = {
    ensureDatabases = [ "mautrix-signal" ];
    ensureUsers = [
      {
        name = "mautrix-signal";
        ensureDBOwnership = true;
      }
    ];
  };

  # portal mappings, sessions, tokens: losing them means relogin and every
  # existing Matrix room orphaned
  lass.backup.state.mautrix-signal.preBackup = ''
    mkdir -p /var/backup/postgresql
    ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
      mautrix-signal | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/mautrix-signal.sql.gz
  '';
}
