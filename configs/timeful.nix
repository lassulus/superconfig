{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  domain = "when.lassul.us";
  port = 3002;
  timeful = self.packages.${pkgs.system}.timeful;
in
{
  lass.ports = {
    ${toString port} = "timeful";
    # mongodb's default, the module has no option for it
    "27017" = "mongodb";
  };

  # timeful (formerly schej): crab.fit/when2meet-style availability polls.
  # Creating a poll and painting availability work without an account;
  # signing in (GitHub OAuth, see pkgs/timeful/self-host.patch) keeps a
  # dashboard of your polls.
  services.mongodb = {
    enable = true;
    # prebuilt binary; the default `mongodb` builds from source for hours
    package = pkgs.mongodb-ce;
  };

  lass.backup.state.timeful.preBackup = ''
    ${pkgs.mongodb-tools}/bin/mongodump --uri=mongodb://127.0.0.1:${toString config.lass.servicePorts.mongodb} \
      --db=schej-it --gzip --archive=/var/backup/timeful.archive.gz
  '';

  clan.core.vars.generators.timeful = {
    files.env = { };
    runtimeInputs = [ pkgs.openssl ];
    # ENCRYPTION_KEY is fed raw to aes.NewCipher, so it must be exactly
    # 16/24/32 bytes (upstream's `openssl rand -base64 32` hint is 44 bytes).
    script = ''
      {
        echo "SESSION_SECRET=$(openssl rand -hex 32)"
        echo "ENCRYPTION_KEY=$(openssl rand -hex 16)"
      } > $out/env
    '';
  };

  # GitHub OAuth app (https://github.com/settings/developers), callback URL
  # https://when.lassul.us/api/auth/github/callback
  clan.core.vars.generators.timeful-github = {
    files.env = { };
    prompts.client_id = {
      description = "GitHub OAuth app client ID for ${domain}";
      persist = true;
    };
    prompts.client_secret = {
      description = "GitHub OAuth app client secret for ${domain}";
      type = "hidden";
      persist = true;
    };
    script = ''
      printf 'GITHUB_CLIENT_ID=%s\nGITHUB_CLIENT_SECRET=%s\n' \
        "$(cat "$prompts"/client_id)" "$(cat "$prompts"/client_secret)" > "$out/env"
    '';
  };

  systemd.services.timeful = {
    description = "timeful availability polls";
    wantedBy = [ "multi-user.target" ];
    requires = [ "mongodb.service" ];
    after = [
      "network.target"
      "mongodb.service"
    ];
    environment = {
      LISTEN_ADDR = "127.0.0.1:${toString port}";
      MONGODB_URI = "mongodb://127.0.0.1:${toString config.lass.servicePorts.mongodb}";
      CORS_ORIGINS = "https://${domain}";
      # no listmonk mailing list; skip its HTTP calls on sign-up
      LISTMONK_ENABLED = "false";
    };
    serviceConfig = {
      ExecStart = "${lib.getExe timeful} -release";
      # The server unconditionally appends everything it prints to
      # ./logs.log, which would grow forever; the journal already has it.
      ExecStartPre = "${pkgs.coreutils}/bin/ln -sfn /dev/null logs.log";
      EnvironmentFile = [
        config.clan.core.vars.generators.timeful.files.env.path
        config.clan.core.vars.generators.timeful-github.files.env.path
      ];
      DynamicUser = true;
      StateDirectory = "timeful";
      WorkingDirectory = "/var/lib/timeful";
      Restart = "on-failure";
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
    };
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      # gin trusts every proxy and takes the leftmost X-Forwarded-For entry
      # for its per-IP rate limiter, so overwrite instead of appending
      # (recommendedProxySettings appends a client-controlled value).
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}
