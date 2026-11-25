{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  domain = "glotz.lassul.us";
  port = config.lass.servicePorts.tv;
  vars = config.clan.core.vars.generators;
  styx = self.inputs.kartei.hosts.styx.nets.retiolum.ip4.addr;
  proxyPort = self.nixosConfigurations.styx.config.lass.servicePorts.tv-proxy;
  pot = pkgs.python3Packages.bgutil-ytdlp-pot-provider;
  tvConfig = pkgs.writeText "tv.json" (
    builtins.toJSON {
      listen = "127.0.0.1:${toString port}";
      state_dir = "/var/lib/tv";
      cache_dir = "/var/cache/tv/media";
      cache_max_bytes = 50 * 1024 * 1024 * 1024;
      secret_file = "/run/credentials/tv.service/secret";
      jellyfin_url = "http://${self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr}:8096";
      jellyfin_key_file = "/run/credentials/tv.service/jellyfin";
      # the YouTube channels live in /var/lib/tv/state.json: api/channels/suggest
      # from the page, api/channels/{add,remove,approve,reject} with the admin key
      youtube_videos_per_channel = 30;
      # fraction of the picked airtime that goes to YouTube
      youtube_share = 0.5;
      # channels like the current ones the LLM adds to the suggestions every week
      channel_suggestions_per_week = 3;
      # yt-dlp master, built on first use: released versions break with YouTube's changes
      yt_dlp = lib.getExe (
        self.packages.${pkgs.stdenv.hostPlatform.system}.yt-dlp.override {
          plugins = [ "bgutil-ytdlp-pot-provider" ];
        }
      );
      # YouTube asks datacenter IPs to sign in, so downloads go through styx's residential line
      yt_dlp_args = [
        "--proxy"
        "socks5://${styx}:${toString proxyPort}"
        # media downloads without a PO token get 403; the script fetches it through --proxy too
        "--extractor-args"
        "youtubepot-bgutilscript:server_home=${pot}/share/bgutil-ytdlp-pot-provider"
        # the default clients never ask for a PO token; mweb does and uses it for the media URLs.
        # formats=dashy splits each format into 10 MiB range fragments so -N fetches 4 at once
        # (YouTube throttles each connection; one extractor-args per extractor, a second replaces the first)
        "--extractor-args"
        "youtube:player_client=default,mweb;formats=dashy"
        "--concurrent-fragments"
        "4"
        # cookies of a Google account; yt-dlp writes rotated cookies back, so a writable copy
        "--cookies"
        "/var/lib/tv/youtube-cookies.txt"
      ];
      ffmpeg = lib.getExe' pkgs.ffmpeg-headless "ffmpeg";
      llm_url = "https://generativelanguage.googleapis.com/v1beta/openai/";
      llm_model = "gemini-3.5-flash-lite";
      llm_key_file = "/run/credentials/tv.service/gemini";
      # plans a TV-guide day; ~3 Mbit/s of prepared files make 24 h about 35 GB of cache_max_bytes
      look_ahead = "24h";
      admin_key_file = "/run/credentials/tv.service/admin";
      # editors log in at id.lassul.us besides the admin key; the callback is outside the secret path
      oidc_issuer = "https://id.lassul.us";
      oidc_client_id_file = "/run/credentials/tv.service/oidc-client-id";
      oidc_redirect_url = "https://${domain}/oidc/callback";
      jellyseerr_url = "http://${self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr}:5055";
      jellyseerr_key_file = "/run/credentials/tv.service/jellyseerr";
      requests_per_day = 2;
      audio_languages = [
        "en"
        "de"
      ];
      subtitle_languages = [
        "en"
        "de"
      ];
      required_languages = [ "en" ];
      sponsorblock_categories = [
        "sponsor"
        "selfpromo"
        "interaction"
      ];
    }
  );
in
{
  lass.ports."8085" = "tv";

  # only users an admin gave a user grant on the project tv in the console can log in to edit the schedule
  lass.zitadel.projects.tv = {
    access = "managed";
    apps.web = {
      redirectUris = [ "https://${domain}/oidc/callback" ];
      authMethod = "none";
    };
  };

  systemd.services.tv = {
    description = "${domain} channel";
    wantedBy = [ "multi-user.target" ];
    # reads the client id that zitadel-reconcile writes
    wants = [
      "network-online.target"
      "zitadel-reconcile.service"
    ];
    after = [
      "network-online.target"
      "zitadel-reconcile.service"
    ];
    # yt-dlp solves YouTube's JavaScript challenges with deno, the PO token script runs on node
    path = [
      pkgs.deno
      pkgs.nodejs
      pkgs.diffutils
    ];
    environment.HOME = "/var/cache/tv";
    # copy the cookies var only when it changed, so cookies rotated by yt-dlp survive restarts
    preStart = ''
      if ! cmp -s "$CREDENTIALS_DIRECTORY/youtube" youtube-cookies.var; then
        install -m 600 "$CREDENTIALS_DIRECTORY/youtube" youtube-cookies.var
        install -m 600 "$CREDENTIALS_DIRECTORY/youtube" youtube-cookies.txt
      fi
    '';
    serviceConfig = {
      WorkingDirectory = "/var/lib/tv";
      ExecStart = "${lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.tv} -config ${tvConfig}";
      DynamicUser = true;
      StateDirectory = "tv";
      CacheDirectory = "tv";
      LoadCredential = [
        "secret:${vars.tv-secret.files.secret.path}"
        "gemini:${vars.tv-gemini.files.key.path}"
        "jellyfin:${vars.tv-jellyfin.files.key.path}"
        "admin:${vars.tv-admin.files.key.path}"
        "jellyseerr:${vars.tv-jellyseerr.files.key.path}"
        "youtube:${vars.tv-youtube.files.cookies.path}"
        "oidc-client-id:${config.lass.zitadel.projects.tv.apps.web.clientIdFile}"
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
  clan.core.vars.generators.tv-jellyseerr.prompts.key = {
    description = "Jellyseerr API key for ${domain}'s movie requests (Jellyseerr: Settings > General > API Key)";
    type = "hidden";
    persist = true;
  };
  clan.core.vars.generators.tv-youtube.prompts.cookies = {
    description = "cookies.txt of the Google account for ${domain}, exported while signed in to YouTube";
    type = "multiline-hidden";
    persist = true;
  };
  # bearer key for the editor endpoints: POST /<secret>/api/skip, api/schedule/*, api/channels/{add,remove,approve,reject}, api/slots/* and GET api/search
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

  # the channel's old name: old links and saved app URLs keep working
  services.nginx.virtualHosts."tv.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    globalRedirect = domain;
  };

  lass.backup.state.tv.folders = [ "/var/lib/private/tv" ];
}
