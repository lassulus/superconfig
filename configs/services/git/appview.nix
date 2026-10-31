{
  self,
  config,
  pkgs,
  ...
}:
let
  domain = "git.lassul.us";
  port = 3010;
  redisPort = 6380;
  listenAddr = "127.0.0.1:${toString port}";
in
{
  lass.ports = {
    ${toString port} = "appview";
    ${toString (port + 1)} = "appview-metrics";
    ${toString redisPort} = "redis-appview";
  };

  # Tangled appview: the web UI for repos on knot.lassul.us (knot.nix) and
  # other knots. Users log in with their atproto account via OAuth to their
  # PDS. Records come from Bluesky's jetstream (upstream default) and repo
  # contents from our knotmirror (knotmirror.nix). Follows tangled's
  # nix/modules/appview.nix, without its flake (the module files are in a
  # fetched source, importing them would be IFD).

  clan.core.vars.generators.tangled-appview = {
    files."appview.env" = { };
    runtimeInputs = with pkgs; [
      atproto-goat
      coreutils
      gawk
      gnugrep
      openssl
    ];
    script = ''
      {
        echo "TANGLED_COOKIE_SECRET=$(openssl rand -hex 32)"
        echo "TANGLED_OAUTH_CLIENT_KID=$(date +%s)"
        echo "TANGLED_OAUTH_CLIENT_SECRET=$(goat key generate -t P-256 | grep -A1 'Secret Key' | tail -n1 | awk '{print $1}')"
      } > "$out/appview.env"
    '';
  };

  # 6379 is docuseal's
  services.redis.servers.appview = {
    enable = true;
    port = redisPort;
  };

  systemd.services.appview = {
    description = "tangled appview service";
    wantedBy = [ "multi-user.target" ];
    after = [
      "redis-appview.service"
      "network-online.target"
    ];
    requires = [ "redis-appview.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.diffutils ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${self.packages.${pkgs.stdenv.hostPlatform.system}.tangled.appview}/bin/appview";
      Restart = "always";
      RestartSec = "10s";
      EnvironmentFile = config.clan.core.vars.generators.tangled-appview.files."appview.env".path;
      # upstream runs it as root
      DynamicUser = true;
      StateDirectory = "appview";
      WorkingDirectory = "/var/lib/appview";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/appview" ];
    };
    # upstream's defaults, except where commented
    environment = {
      TANGLED_DB_PATH = "/var/lib/appview/appview.db";
      TANGLED_LISTEN_ADDR = listenAddr;
      TANGLED_METRICS_LISTEN_ADDR = "127.0.0.1:${toString (port + 1)}";
      TANGLED_APPVIEW_HOST = domain;
      TANGLED_APPVIEW_NAME = domain;
      TANGLED_DEV = "false";
      TANGLED_REDIS_ADDR = "127.0.0.1:${toString redisPort}";
      TANGLED_REDIS_DB = "0";
      TANGLED_JETSTREAM_ENDPOINT = "wss://jetstream1.us-east.bsky.network/subscribe";
      TANGLED_KNOTSTREAM_RETRY_INTERVAL = "60s";
      TANGLED_KNOTSTREAM_MAX_RETRY_INTERVAL = "120m";
      TANGLED_KNOTSTREAM_CONNECTION_TIMEOUT = "5s";
      TANGLED_KNOTSTREAM_WORKER_COUNT = "64";
      TANGLED_KNOTSTREAM_QUEUE_SIZE = "100";
      TANGLED_SPINDLESTREAM_RETRY_INTERVAL = "60s";
      TANGLED_SPINDLESTREAM_MAX_RETRY_INTERVAL = "120m";
      TANGLED_SPINDLESTREAM_CONNECTION_TIMEOUT = "5s";
      TANGLED_SPINDLESTREAM_WORKER_COUNT = "64";
      TANGLED_SPINDLESTREAM_QUEUE_SIZE = "100";
      TANGLED_RESEND_SENT_FROM = "noreply@notifs.tangled.sh";
      # sends logins, searches and pushes even without an API key
      TANGLED_POSTHOG_ENDPOINT = "http://127.0.0.1:9";
      TANGLED_CAMO_HOST = "https://camo.tangled.sh";
      TANGLED_AVATAR_HOST = "https://avatar.tangled.sh";
      TANGLED_PLC_URL = "https://plc.directory";
      TANGLED_PDS_HOST = "https://tngl.sh";
      # records of tangled's account, fetched from its PDS at startup; repos
      # start without labels
      TANGLED_LABEL_DEFAULTS = "";
      TANGLED_LABEL_GFI = "at://did:plc:wshs7t2adsemcrrd4snkeqli/sh.tangled.label.definition/good-first-issue";
      # probed at every login, upstream's is knot1.tangled.sh
      TANGLED_KNOT_DEFAULT = "knot.lassul.us";
      # OG images of repos, issues and pulls, rendered by tangled
      TANGLED_OGRE_HOST = "http://127.0.0.1:9";
      # browsers get raw blob links to it, so not localhost
      TANGLED_KNOTMIRROR_URL = "https://mirror.lassul.us";
    };
  };

  # redis only caches
  lass.backup.state.tangled-appview = {
    preBackup = ''
      ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" /var/lib/private/appview/appview.db ".backup /var/backup/tangled-appview.db"
    '';
    # WAL-mode SQLite readers need to write the -shm file
    readWritePaths = [ "/var/lib/private/appview" ];
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${listenAddr}";
      recommendedProxySettings = true;
      proxyWebsockets = true;
    };
    # creates tngl.sh accounts, which needs tangled's PDS admin secret
    locations."/signup".return = "404";
  };
}
