{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  domain = "tv.lassul.us";
  port = config.lass.servicePorts.tv;
  vars = config.clan.core.vars.generators;
  styx = self.inputs.kartei.hosts.styx.nets.retiolum.ip4.addr;
  proxyPort = self.nixosConfigurations.styx.config.lass.servicePorts.tv-proxy;
  tvConfig = pkgs.writeText "tv.json" (
    builtins.toJSON {
      listen = "127.0.0.1:${toString port}";
      state_dir = "/var/lib/tv";
      cache_dir = "/var/cache/tv/media";
      cache_max_bytes = 50 * 1024 * 1024 * 1024;
      secret_file = "/run/credentials/tv.service/secret";
      jellyfin_url = "http://${self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr}:8096";
      jellyfin_key_file = "/run/credentials/tv.service/jellyfin";
      youtube_channels = map (name: "https://www.youtube.com/@${name}/videos") [
        "halfasinteresting"
        "HistoryBuffs"
        "3blue1brown"
        "FredrikKnudsen"
        "hbomberguy"
        "KnowingBetter"
        "kurzgesagt"
        "MandaloreGaming"
        "MinutePhysics"
      ];
      yt_dlp = lib.getExe pkgs.yt-dlp;
      # YouTube asks datacenter IPs to sign in, so downloads go through styx's residential line
      yt_dlp_args = [
        "--proxy"
        "socks5://${styx}:${toString proxyPort}"
      ];
      ffmpeg = lib.getExe' pkgs.ffmpeg-headless "ffmpeg";
      llm_url = "https://generativelanguage.googleapis.com/v1beta/openai/";
      llm_model = "gemini-3.5-flash-lite";
      llm_key_file = "/run/credentials/tv.service/gemini";
      look_ahead = "3h";
      admin_key_file = "/run/credentials/tv.service/admin";
    }
  );
in
{
  lass.ports."8085" = "tv";

  systemd.services.tv = {
    description = "${domain} channel";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # yt-dlp solves YouTube's JavaScript challenges with deno from PATH
    path = [ pkgs.deno ];
    environment.HOME = "/var/cache/tv";
    serviceConfig = {
      ExecStart = "${lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.tv} -config ${tvConfig}";
      DynamicUser = true;
      StateDirectory = "tv";
      CacheDirectory = "tv";
      LoadCredential = [
        "secret:${vars.tv-secret.files.secret.path}"
        "gemini:${vars.tv-gemini.files.key.path}"
        "jellyfin:${vars.tv-jellyfin.files.key.path}"
        "admin:${vars.tv-admin.files.key.path}"
      ];
      Restart = "on-failure";
      # transcodes take every free core; everything else on neoprism goes first
      CPUWeight = "idle";
      Nice = 19;
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      # ffmpeg gets the Jellyfin key on its command line
      ProtectProc = "invisible";
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

  clan.core.vars.generators.tv-secret = {
    files.secret = { };
    # nginx only rate limits requests outside of the secret path
    files."nginx.conf".owner = "nginx";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -base64 64 | tr -dc A-Za-z0-9 | cut -c 1-6 | tr -d '\n' > "$out/secret"
      printf 'map $uri $tv_guess { "~^/%s/" ""; default $binary_remote_addr; }\n' "$(cat "$out/secret")" > "$out/nginx.conf"
    '';
  };
  clan.core.vars.generators.tv-gemini.prompts.key = {
    description = "Gemini API key for ${domain}'s picker (aistudio.google.com/apikey)";
    type = "hidden";
    persist = true;
  };
  clan.core.vars.generators.tv-jellyfin.prompts.key = {
    description = "Jellyfin API key for ${domain} (flix.lassul.us: Dashboard > API Keys)";
    type = "hidden";
    persist = true;
  };
  # bearer key for POST /<secret>/api/skip
  clan.core.vars.generators.tv-admin = {
    files.key = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -base64 64 | tr -dc A-Za-z0-9 | cut -c 1-32 | tr -d '\n' > "$out/key"
    '';
  };

  # Every miss of the 6-character secret is limited to 1/s per IP; requests
  # inside the secret path (page, api/time polling, media ranges) are not
  # counted, since their key is empty.
  services.nginx.appendHttpConfig = ''
    include ${vars.tv-secret.files."nginx.conf".path};
    limit_req_zone $tv_guess zone=tv:1m rate=1r/s;
  '';
  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      extraConfig = ''
        limit_req zone=tv burst=10;
        limit_req_status 429;
        proxy_buffering off;
      '';
    };
  };

  lass.backup.state.tv.folders = [ "/var/lib/private/tv" ];
}
