{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = "mirror.lassul.us";
  listenAddr = "127.0.0.1:${toString config.lass.servicePorts.knotmirror}";
  tapPort = 7480;
  redisPort = 6377;
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.tangled.knotmirror;
in
{
  lass.ports = {
    "7000" = "knotmirror";
    "7100" = "knotmirror-metrics";
    "7200" = "knotmirror-admin";
    ${toString tapPort} = "knotmirror-tap";
    ${toString redisPort} = "redis-knotmirror";
    ${toString config.services.postgresql.settings.port} = "postgresql";
  };

  # Tangled knotmirror: the appview reads repo contents from here instead of
  # mirror.tangled.network. It mirrors a repo the first time the appview asks
  # for it (resolving the knot from the repo's DID) and follows the event
  # streams of knots that requested a crawl (ours, see knot.nix). Public,
  # since the appview links browsers to raw blobs and images on it. Follows
  # tangled's nix/modules/knotmirror.nix, without its flake (the module files
  # are in a fetched source, importing them would be IFD); tap is nixpkgs'.

  environment.systemPackages = [
    pkgs.git
    package
  ];

  services.redis.servers.knotmirror = {
    enable = true;
    port = redisPort;
  };

  systemd.services.tap-knotmirror = {
    description = "knotmirror tap service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # outbox only: no firehose subscription to the bsky relay for nothing
    environment.TAP_OUTBOX_ONLY = "true";
    serviceConfig = {
      # upstream runs it as root
      DynamicUser = true;
      LogsDirectory = "knotmirror-tap";
      StateDirectory = "knotmirror-tap";
      Environment = [
        "TAP_BIND=:${toString tapPort}"
        "TAP_PLC_URL=https://plc.directory"
        "TAP_RELAY_URL=https://relay1.us-east.bsky.network"
        "TAP_RESYNC_PARALLELISM=10"
        "TAP_DATABASE_URL=sqlite:///var/lib/knotmirror-tap/tap.db"
        "TAP_RETRY_TIMEOUT=60s"
        "TAP_COLLECTION_FILTERS=sh.tangled.repo"
        # nothing calls tap's /repos/add without the full network, so it
        # tracks no repos
        "TAP_FULL_NETWORK=false"
      ];
      ExecStart = "${lib.getExe pkgs.tap} run";
    };
  };

  systemd.services.knotmirror = {
    description = "knotmirror service";
    after = [
      "postgresql.target"
      "redis-knotmirror.service"
      "network.target"
      "tap-knotmirror.service"
    ];
    requires = [
      "postgresql.target"
      "redis-knotmirror.service"
    ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.git ];
    # pinged after indexing languages, upstream's is tangled.org
    environment.MIRROR_APPVIEW_URL = "https://git.lassul.us";
    serviceConfig = {
      # upstream runs it as root; the name matches the postgres role for peer
      # auth
      DynamicUser = true;
      User = "knotmirror";
      LogsDirectory = "knotmirror";
      StateDirectory = "knotmirror";
      Environment = [
        "MIRROR_LISTEN=${listenAddr}"
        "MIRROR_HOSTNAME=${domain}"
        "MIRROR_TAP_URL=http://localhost:${toString tapPort}"
        "MIRROR_DB_URL=postgres:///knotmirror?host=/run/postgresql&user=knotmirror"
        "MIRROR_REDIS_ADDR=localhost:${toString redisPort}"
        "MIRROR_GIT_BASEPATH=/var/lib/knotmirror/repos"
        "MIRROR_KNOT_USE_SSL=true"
        "MIRROR_KNOT_SSRF=true"
        "MIRROR_RESYNC_PARALLELISM=12"
        "MIRROR_METRICS_LISTEN=127.0.0.1:${toString config.lass.servicePorts.knotmirror-metrics}"
        "MIRROR_ADMIN_LISTEN=127.0.0.1:${toString config.lass.servicePorts.knotmirror-admin}"
        "MIRROR_SLURPER_CONCURRENCY=4"
        "MIRROR_SEARCH_ZOEKT_URL="
      ];
      ExecStart = "${lib.getExe package} serve";
      Restart = "always";
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "knotmirror" ];
    ensureUsers = [
      {
        name = "knotmirror";
        ensureDBOwnership = true;
      }
    ];
  };

  # no backup: postgres, redis, tap and the repos only cache what the knots
  # serve, and the mirror refetches it

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${listenAddr}";
      recommendedProxySettings = true;
      # reads only: sh.tangled.sync.requestCrawl (POST) would let anyone
      # subscribe us to any knot, ours requests it via localhost
      extraConfig = ''
        limit_except GET {
          deny all;
        }
        proxy_read_timeout 10m;
      '';
    };
  };
}
