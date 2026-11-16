{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  domain = "games.lassul.us";
  oauth2Proxy = "127.0.0.1:${toString config.lass.servicePorts.games-oauth2-proxy}";
in
{
  lass.ports."4185" = "games-oauth2-proxy";

  # Gamarr's web UI on yellow, public behind a login on id.lassul.us. Only
  # users an admin granted the Zitadel project below in the console can log
  # in; Gamarr itself trusts the proxy (auth method External, default.nix).
  lass.zitadel.projects.games = {
    access = "managed";
    apps.web = {
      redirectUris = [ "https://${domain}/oauth2/callback" ];
      envFile = {
        clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
        clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
      };
    };
  };
  systemd.services.games-oauth2-proxy = {
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
        "--cookie-name=_games_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.lass.zitadel.projects.games.apps.web.envFile.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.games-oauth2-proxy.files."cookie-secret".path
      }";
      DynamicUser = true;
      Restart = "on-failure";
    };
  };
  clan.core.vars.generators.games-oauth2-proxy = {
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
      "/" = {
        proxyPass = "http://${self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr}:6969";
        proxyWebsockets = true;
        recommendedProxySettings = true;
        extraConfig = ''
          auth_request /oauth2/auth;
          error_page 401 = @login;
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
