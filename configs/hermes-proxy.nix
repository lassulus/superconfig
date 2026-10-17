{ lib, ... }:
let
  upstream = "http://coaxmetal.r:8642";

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
  # the voice page for the phone. hermes-voice gates every API route with its
  # own access token, so nothing is filtered by path here. /delegate streams
  # NDJSON for the length of a Hermes turn, so the streaming settings apply.
  services.nginx.virtualHosts."assist.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    extraConfig = ''
      client_max_body_size 256k;
    '';
    locations."/" = {
      recommendedProxySettings = true;
      proxyPass = "http://coaxmetal.r:8790";
      extraConfig = streamingProxy;
    };
  };

  # One phone driving one agent needs a trickle of requests; a turn is a single
  # long-lived request, not a stream of them. This is sized to absorb the
  # settings screens refreshing (hence the burst) while making credential
  # stuffing against the bearer token pointless.
  services.nginx.appendHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=hermes_api:1m rate=60r/m;
  '';
}
