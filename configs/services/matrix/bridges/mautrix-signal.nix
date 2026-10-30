{
  config,
  lib,
  pkgs,
  ...
}:
let
  appservices = config.lass.matrix-appservices;
  appservice = appservices.bridges.signal;
in
{
  services.mautrix-signal = {
    enable = true;
    # use pure-Go olm implementation to avoid the insecure libolm dependency
    package = pkgs.mautrix-signal.override { withGoolm = true; };
    environmentFile = config.clan.core.vars.generators.mautrix-signal.files.env.path;
    settings = {
      homeserver = {
        address = appservices.homeserver;
        domain = "lassul.us";
      };
      appservice = {
        inherit (appservice) address port;
        hostname = "0.0.0.0";
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
  systemd.services.mautrix-signal = {
    serviceConfig.LoadCredential = [ "appservice:${appservice.tokens}" ];
    preStart = lib.mkBefore ''
      ${appservice.writeRegistration} "$CREDENTIALS_DIRECTORY/appservice" /var/lib/mautrix-signal/signal-registration.yaml
    '';
  };

  # pickle_key encrypts the bridge's olm account in its database: it has to
  # stay the same for the life of that crypto store
  clan.core.vars.generators.mautrix-signal = {
    files.env = { };
    runtimeInputs = [ pkgs.pwgen ];
    script = ''
      printf 'ENCRYPTION_PICKLE_KEY=%s\n' "$(pwgen -s 64 1)" > "$out"/env
    '';
  };

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
