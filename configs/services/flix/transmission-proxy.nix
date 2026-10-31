{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  domain = "transmission.lassul.us";
  oauth2Proxy = "127.0.0.1:4182";
in
{
  # Transmission's web UI on yellow, public behind a login on id.lassul.us.
  # Only users an admin granted the Zitadel project below in the console can
  # log in. services.oauth2-proxy is single-instance and taken by
  # assist.lassul.us (configs/hermes-proxy.nix), so this is its own unit.
  lass.zitadel.projects.transmission = {
    access = "managed";
    apps.web = {
      redirectUris = [ "https://${domain}/oauth2/callback" ];
      envFile = {
        clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
        clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
      };
    };
  };
  systemd.services.transmission-oauth2-proxy = {
    description = "${domain} login (id.lassul.us)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "zitadel-reconcile.service" ];
    after = [
      "network-online.target"
      "zitadel-reconcile.service"
    ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.oauth2-proxy)
        "--provider=oidc"
        "--oidc-issuer-url=https://id.lassul.us"
        "--redirect-url=https://${domain}/oauth2/callback"
        "--http-address=${oauth2Proxy}"
        # who may log in is decided by the grant on the Zitadel project
        "--email-domain=*"
        "--cookie-name=_transmission_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.lass.zitadel.projects.transmission.apps.web.envFile.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.transmission-oauth2-proxy.files."cookie-secret".path
      }";
      DynamicUser = true;
      Restart = "on-failure";
    };
  };
  clan.core.vars.generators.transmission-oauth2-proxy = {
    files."cookie-secret" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/cookie-secret"
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations = {
      # yellow's nginx serves transmission under the name transmission.r
      # (configs/services/flix/default.nix); its default vhost is the
      # download index, so the Host header has to say transmission.r.
      "/" = {
        proxyPass = "http://${self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr}";
        extraConfig = ''
          auth_request /oauth2/auth;
          error_page 401 = @login;
          proxy_set_header Host transmission.r;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          # .torrent uploads go through the RPC as base64
          client_max_body_size 20m;
        '';
      };
      "/oauth2/" = {
        recommendedProxySettings = true;
        proxyPass = "http://${oauth2Proxy}";
      };
      "= /oauth2/auth" = {
        recommendedProxySettings = true;
        proxyPass = "http://${oauth2Proxy}";
        extraConfig = ''
          proxy_pass_request_body off;
          proxy_set_header Content-Length "";
        '';
      };
      "@login".return = "307 /oauth2/start?rd=$request_uri";
    };
  };
}
