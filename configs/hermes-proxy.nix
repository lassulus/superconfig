{
  config,
  lib,
  pkgs,
  ...
}:
let
  upstream = "http://coaxmetal.r:8642";
  assist = "assist.lassul.us";
  voiceUpstream = "http://coaxmetal.r:8790";
  oauth2Proxy = config.services.oauth2-proxy.httpAddress;
  voiceAuthHeader = "/run/hermes-voice-auth/authorization.conf";

  # Agent turns run for minutes and /v1/chat/completions streams SSE chunks the
  # whole time. nginx's default 60s proxy_read_timeout would cut a long turn off
  # mid-answer, and its response buffering would hold the stream back until the
  # turn ended, so the phone would sit silent and then dump everything at once.
  # coaxmetal is a laptop — asleep or off the mesh most of the day — so connect
  # fails fast, to report "unreachable" instead of hanging on the assistant
  # button.
  streamingProxy = ''
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
    proxy_buffering off;
    proxy_cache off;
    proxy_connect_timeout 5s;
    limit_req zone=hermes_api burst=20 nodelay;
  '';

  proxied = {
    recommendedProxySettings = true;
    proxyPass = upstream;
    extraConfig = streamingProxy;
  };

  # Endpoints WakeHermesClaw actually calls, taken from its sources
  # (backend/HermesApiServerClient.kt and friends): the chat/runs lanes plus the
  # read-only lanes its settings screens populate from. Everything else — most
  # of the adapter's route table — is unreachable from outside.
  allowed = [
    "= /health"
    "/v1/"
    "= /api/config"
    "= /api/available-models"
    "= /api/model/options"
    "= /api/skills"
    "= /api/jobs"
    "/api/jobs/"
    "/api/profiles"
  ];
in
{
  imports = [ ./hermes-voice-vars.nix ];

  # Public door to the Hermes API server on coaxmetal (machines/coaxmetal/hermes.nix).
  # This is what the WakeHermesClaw app on massulus points at when it is not on
  # retiolum: the assistant button posts to /v1/chat/completions here.
  #
  # SECURITY: behind this vhost sits an agent with terminal tools. The
  # gateway's only check on this
  # lane is the API_SERVER_KEY bearer token — there is no per-user allowlist like
  # MATRIX_ALLOWED_USERS on the Matrix lane, and the app cannot do mTLS (it
  # builds a bare OkHttpClient with no KeyManager), so a client certificate is
  # not an option without patching it. That token is therefore a
  # root-equivalent credential for that laptop: rotate it by regenerating the
  # hermes-api var. The hardening below is damage control, not authentication.
  services.nginx.virtualHosts."hermes.lassul.us" = {
    enableACME = true;
    forceSSL = true;

    # Attachments: the app can send images with a prompt. 25M is generous for a
    # phone photo and still bounds what an unauthenticated request can push
    # into the proxy before hermes rejects it.
    extraConfig = ''
      client_max_body_size 25m;
    '';

    # Unlisted paths never reach hermes. Notably /api/pty and /api/ws — the
    # Hermes Desktop terminal lane — are only served with backend.mode
    # "serve"/"dashboard", which this host does not enable; 404ing them here
    # means enabling it later cannot quietly publish a PTY.
    locations = lib.genAttrs allowed (_: proxied) // {
      "/".extraConfig = ''
        return 404;
      '';
    };
  };

  # Public door to hermes-voice on coaxmetal (machines/coaxmetal/hermes-voice.nix):
  # the voice page for the phone. Everything but the files Chrome fetches
  # without cookies to install the page needs a login on id.lassul.us
  # (oauth2-proxy below, via auth_request); logged-in requests get
  # hermes-voice's access token added. /app/ is the Android app's door: no
  # web login, the app's own bearer token goes through to hermes-voice, which
  # checks it. /delegate streams NDJSON for the length of a Hermes turn, so
  # the streaming settings apply.
  services.nginx.virtualHosts.${assist} = {
    enableACME = true;
    forceSSL = true;
    extraConfig = ''
      client_max_body_size 256k;
      auth_request /oauth2/auth;
      error_page 401 = @login;
    '';
    locations =
      lib.genAttrs
        [
          "= /manifest.webmanifest"
          "= /icon-192.png"
          "= /icon-512.png"
        ]
        (_: {
          proxyPass = voiceUpstream;
          extraConfig = ''
            auth_request off;
          '';
        })
      // {
        "/" = {
          recommendedProxySettings = true;
          proxyPass = voiceUpstream;
          extraConfig = streamingProxy + ''
            include ${voiceAuthHeader};
          '';
        };
        "/app/" = {
          recommendedProxySettings = true;
          proxyPass = "${voiceUpstream}/";
          extraConfig = streamingProxy + ''
            auth_request off;
          '';
        };
        "/oauth2/" = {
          recommendedProxySettings = true;
          proxyPass = oauth2Proxy;
          extraConfig = ''
            auth_request off;
          '';
        };
        "= /oauth2/auth" = {
          recommendedProxySettings = true;
          proxyPass = oauth2Proxy;
          extraConfig = ''
            auth_request off;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
          '';
        };
        "@login" = {
          return = "307 /oauth2/start?rd=$request_uri";
          extraConfig = ''
            auth_request off;
          '';
        };
      };
  };

  # Login for assist.lassul.us: only users with a grant on the Zitadel
  # project, and of those only this verified address. Sessions are keyed by
  # `sub`. zitadel-reconcile writes the client id/secret to the keyFile.
  lass.zitadel.projects.assist = {
    access = "declarative";
    users = [ "lass@lassul.us" ];
    apps.web = {
      redirectUris = [ "https://${assist}/oauth2/callback" ];
      envFile = {
        clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
        clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
      };
    };
  };
  # "http://127.0.0.1:4180" -> "4180"
  lass.ports.${lib.last (lib.splitString ":" oauth2Proxy)} = "oauth2-proxy";
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://id.lassul.us";
    keyFile = config.lass.zitadel.projects.assist.apps.web.envFile.path;
    redirectURL = "https://${assist}/oauth2/callback";
    email.addresses = "lass@lassul.us";
    cookie.secretFile = config.clan.core.vars.generators.oauth2-proxy.files."cookie-secret".path;
    extraConfig.skip-provider-button = true;
  };
  systemd.services.oauth2-proxy = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
  };
  clan.core.vars.generators.oauth2-proxy = {
    files."cookie-secret" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/cookie-secret"
    '';
  };

  # The Authorization header with hermes-voice's access token, as an nginx
  # include readable only by nginx. A switch reloads nginx through
  # nginx-config-reload instead of starting nginx, so the include has to be in
  # place before either, and multi-user.target starts it on a switch that
  # newly adds this unit.
  systemd.services.hermes-voice-auth-header = {
    wantedBy = [ "multi-user.target" ];
    before = [
      "nginx.service"
      "nginx-config-reload.service"
    ];
    requiredBy = [
      "nginx.service"
      "nginx-config-reload.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "hermes-voice-auth";
      RuntimeDirectoryPreserve = true;
      UMask = "0077";
    };
    script = ''
      token=$(cat ${config.clan.core.vars.generators.hermes-voice.files."access-token".path})
      printf 'proxy_set_header Authorization "Bearer %s";\n' "$token" > ${voiceAuthHeader}.tmp
      chown ${config.services.nginx.user} ${voiceAuthHeader}.tmp
      mv ${voiceAuthHeader}.tmp ${voiceAuthHeader}
    '';
  };

  # One phone driving one agent needs a trickle of requests; a turn is a single
  # long-lived request, not a stream of them. This is sized to absorb the
  # settings screens refreshing (hence the burst) while making credential
  # stuffing against the bearer token pointless.
  services.nginx.appendHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=hermes_api:1m rate=60r/m;
  '';
}
