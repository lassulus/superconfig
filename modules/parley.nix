{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.lass.parley;
  generators = config.clan.core.vars.generators;
in
{
  options.lass.parley = {
    enable = lib.mkEnableOption "parley, federated chat that speaks plain IRC";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.parley;
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        PARLEY_DOMAIN = "example.com";
        PARLEY_ENDPOINT = "https://chat.example.com";
      };
      description = "PARLEY_* environment variables for parleyd (upstream README, Configuration).";
    };

    users = lib.mkOption {
      default = { };
      description = ''
        Local accounts. Each gets a generated password
        (`clan vars get <machine> parley-user-<nick>/password`); after every
        start the account is created, or reset to its declared role and
        password. Accounts not listed here are left alone.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.role = lib.mkOption {
            type = lib.types.enum [
              "admin"
              "user"
              "bot"
            ];
            default = "user";
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    lass.parley.settings = {
      PARLEY_DATA_DIR = "/var/lib/parley";
      PARLEY_IRC_LISTEN = lib.mkDefault "127.0.0.1:6667";
      PARLEY_HTTP_LISTEN = lib.mkDefault "127.0.0.1:8443";
    };

    clan.core.vars.generators = {
      parley = {
        # The instance key is the domain's identity: peers cache its public
        # half, so regenerating it is a key rotation every peer has to re-learn.
        files."identity.key" = { };
        files."env" = { };
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          # parley's key format: base64 of a 32-byte ed25519 seed
          openssl rand -base64 32 > "$out/identity.key"
          echo "PARLEY_ADMIN_TOKEN=$(openssl rand -hex 32)" > "$out/env"
        '';
      };
    }
    // lib.mapAttrs' (
      nick: _:
      lib.nameValuePair "parley-user-${nick}" {
        files."password" = { };
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          openssl rand -hex 24 > "$out/password"
        '';
      }
    ) cfg.users;

    users.users.parley = {
      isSystemUser = true;
      group = "parley";
    };
    users.groups.parley = { };

    environment.systemPackages = [ cfg.package ];

    systemd.services.parley = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = cfg.settings;
      path = [
        cfg.package
        pkgs.curl
      ];
      preStart = ''
        install -m 0600 "$CREDENTIALS_DIRECTORY/identity.key" identity.key
      '';
      postStart = lib.optionalString (cfg.users != { }) ''
        export PARLEY_ENDPOINT=http://$PARLEY_HTTP_LISTEN
        until curl -fs -o /dev/null "$PARLEY_ENDPOINT/healthz"; do sleep 1; done
        ${lib.concatStrings (
          lib.mapAttrsToList (nick: user: ''
            pw="$CREDENTIALS_DIRECTORY/user-${nick}"
            parleyctl accounts update ${nick} -role ${user.role} -password-stdin < "$pw" > /dev/null \
              || parleyctl accounts create ${nick} -role ${user.role} -password-stdin < "$pw" > /dev/null
          '') cfg.users
        )}
      '';
      serviceConfig = {
        ExecStart = lib.getExe' cfg.package "parleyd";
        User = "parley";
        Group = "parley";
        StateDirectory = "parley";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/parley";
        UMask = "0077";
        EnvironmentFile = generators.parley.files."env".path;
        LoadCredential = [
          "identity.key:${generators.parley.files."identity.key".path}"
        ]
        ++ lib.mapAttrsToList (
          nick: _: "user-${nick}:${generators."parley-user-${nick}".files."password".path}"
        ) cfg.users;
        Restart = "on-failure";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
      };
    };

    # identity.key also lives in clan vars; the SQLite databases are dumped
    # consistently instead of copied.
    lass.backup.state.parley = {
      folders = [ "/var/lib/parley" ];
      exclude = [ "/var/lib/parley/*.db*" ];
      preBackup = ''
        mkdir -p /var/backup/parley
        for db in parley history; do
          ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" "/var/lib/parley/$db.db" ".backup /var/backup/parley/$db.db"
        done
      '';
      # WAL-mode SQLite readers need to write the -shm file
      readWritePaths = [ "/var/lib/parley" ];
    };
  };
}
