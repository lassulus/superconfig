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
  dataDir = "/var/lib/mautrix-telegram";
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.mautrix-telegram-go;

  # bridgev2 config; the bridge fills in every key left out from its example
  # config. Not the nixpkgs services.mautrix-telegram module: that one is for
  # the Python bridge and merges Python defaults (appservice.database, the
  # logging dict) into the config, which makes the Go bridge treat it as a
  # legacy config to migrate.
  settings = {
    homeserver = {
      address = appservices.homeserver;
      domain = "lassul.us";
    };
    appservice = {
      inherit (appservice) address port;
      hostname = "0.0.0.0";
      id = "telegram";
      bot.username = "telegrambot";
      ephemeral_events = true;
      # the ghosts the Python bridge created (`telegram_{userid}`)
      username_template = "telegram_{{.}}";
    };
    database = {
      type = "postgres";
      uri = "postgres:///mautrix-telegram?host=/run/postgresql";
    };
    network = {
      displayname_template = "{{ if .Deleted }}Deleted account {{ .UserID }}{{ else }}{{ .FullName }}{{ end }} (TG)";
      # portals for every chat, DMs included, not only the 15 most recent
      sync = {
        update_limit = -1;
        create_limit = -1;
        direct_chats = true;
      };
    };
    matrix = {
      delivery_receipts = false;
      message_status_events = false;
    };
    bridge = {
      personal_filtering_spaces = true;
      permissions = {
        "lassul.us" = "user";
        "@lassulus:lassul.us" = "admin";
      };
    };
    # Synapse has no batch sending, so only forward backfill: recent history
    # of new portals and what was missed while the bridge was down
    backfill = {
      enabled = true;
      max_initial_messages = 50;
      max_catchup_messages = 500;
    };
    encryption = {
      allow = true;
      default = true;
      require = false;
      # the fixed key the Python bridge pickled its olm account with; the
      # migration keeps that crypto store
      pickle_key = "mautrix.bridge.e2ee";
    };
    provisioning.shared_secret = "disable";
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
  configTemplate = (pkgs.formats.json { }).generate "mautrix-telegram-config.json" settings;
in
{
  users.users.mautrix-telegram = {
    isSystemUser = true;
    group = "mautrix-telegram";
    home = dataDir;
  };
  users.groups.mautrix-telegram = { };

  systemd.services.mautrix-telegram = {
    description = "mautrix-telegram, a Matrix-Telegram puppeting bridge";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # sticker conversion
    path = [
      pkgs.lottieconverter
      pkgs.ffmpeg-headless
    ];

    # the secrets go into the config only at runtime: the appservice tokens
    # Synapse has in its registration (./appservices.nix), the double puppet
    # token and api_id/api_hash from https://my.telegram.org/apps
    preStart = ''
      set -a
      . "$CREDENTIALS_DIRECTORY/appservice"
      . "$CREDENTIALS_DIRECTORY/telegram"
      DOUBLEPUPPET_AS_TOKEN=$(. "$CREDENTIALS_DIRECTORY/doublepuppet" && echo "$AS_TOKEN")
      set +a
      umask 077
      ${lib.getExe pkgs.jq} '
        .appservice.as_token = env.AS_TOKEN
        | .appservice.hs_token = env.HS_TOKEN
        | .double_puppet.secrets."lassul.us" = "as_token:" + env.DOUBLEPUPPET_AS_TOKEN
        | .network.api_id = (env.MAUTRIX_TELEGRAM_TELEGRAM_API_ID | tonumber)
        | .network.api_hash = env.MAUTRIX_TELEGRAM_TELEGRAM_API_HASH
      ' ${configTemplate} > ${dataDir}/config.json
    '';

    serviceConfig = {
      User = "mautrix-telegram";
      Group = "mautrix-telegram";
      StateDirectory = "mautrix-telegram";
      WorkingDirectory = dataDir;
      LoadCredential = [
        "appservice:${appservice.tokens}"
        "doublepuppet:${appservices.doublepuppet.tokens}"
        "telegram:${config.clan.core.vars.generators.mautrix-telegram.files.env.path}"
      ];
      # --no-update: the config is regenerated on every start anyway
      ExecStart = "${lib.getExe package} --no-update --config ${dataDir}/config.json";
      Restart = "on-failure";
      RestartSec = "30s";
      UMask = "0027";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      PrivateUsers = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallErrorNumber = "EPERM";
      SystemCallFilter = [ "@system-service" ];
    };
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

  # the variable names are the Python bridge's, the preStart above maps them
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
