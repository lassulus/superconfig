{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  yellow = self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr;
  oauth2Proxy = "127.0.0.1:${toString config.lass.servicePorts.flix-oauth2-proxy}";

  # host -> backend; api: phone apps (e.g. nzb360) can't do the browser
  # login, so /api/ skips it where the backend checks its own API key there.
  backends = {
    # yellow's nginx serves transmission under the name transmission.r
    # (default.nix); its default vhost is the download index. Its RPC has
    # no auth of its own, so no bypass.
    "transmission.lassul.us" = {
      proxyPass = "http://${yellow}";
      recommendedProxySettings = false;
      extraConfig = ''
        proxy_set_header Host transmission.r;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # .torrent uploads go through the RPC as base64
        client_max_body_size 20m;
      '';
    };
    # Gamarr trusts the proxy (auth method External, default.nix)
    "games.lassul.us".proxyPass = "http://${yellow}:6969";
    # Bookshelf only serves its API key to logged-in browsers
    # (/initialize.json)
    "bookshelf.lassul.us" = {
      proxyPass = "http://${yellow}:8787";
      api = true;
    };
    "flex.lassul.us" = {
      proxyPass = "http://radar.r:7878";
      api = true;
    };
    "flux.lassul.us" = {
      proxyPass = "http://sonar.r:8989";
      api = true;
    };
    # yellow's download index
    "flax.lassul.us".proxyPass = "http://yellow.r";
  };

  vhost =
    {
      proxyPass,
      extraConfig ? "",
      api ? false,
      recommendedProxySettings ? true,
    }:
    {
      enableACME = true;
      forceSSL = true;
      locations = {
        "/" = {
          inherit proxyPass recommendedProxySettings;
          proxyWebsockets = recommendedProxySettings;
          extraConfig = ''
            auth_request /oauth2/auth;
            error_page 401 = @login;
          ''
          + extraConfig;
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
      }
      // lib.optionalAttrs api {
        "/api/" = {
          inherit proxyPass;
          recommendedProxySettings = true;
        };
      };
    };
in
{
  lass.ports."4182" = "flix-oauth2-proxy";

  # Backends of flix, only for users whose grant on the Zitadel project flix
  # (proxy.nix) has the role backend; the role arrives as the flat groups
  # claim (modules/zitadel). services.oauth2-proxy is taken by
  # assist.lassul.us (configs/hermes-proxy.nix), so this is its own unit.
  lass.zitadel.projects.flix.apps.backends = {
    redirectUris = map (host: "https://${host}/oauth2/callback") (lib.attrNames backends);
    envFile = {
      clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
      clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
    };
  };
  systemd.services.flix-oauth2-proxy = {
    description = "flix backends login (id.lassul.us)";
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
        # without a host it is taken from the request, so every backend
        # host gets its own callback
        "--redirect-url=/oauth2/callback"
        "--reverse-proxy=true"
        "--http-address=${oauth2Proxy}"
        "--email-domain=*"
        "--oidc-groups-claim=groups"
        "--allowed-group=backend"
        # else --allowed-group adds the scope groups, which Zitadel doesn't
        # know; the claim comes from the action anyway
        "--scope=openid email profile"
        # Host-only cookies: one for all of .lassul.us would be sent to every
        # other vhost there. The other hosts log in through Zitadel's
        # session without a prompt.
        "--cookie-name=_flix_backends_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.lass.zitadel.projects.flix.apps.backends.envFile.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.flix-oauth2-proxy.files."cookie-secret".path
      }";
      DynamicUser = true;
      Restart = "on-failure";
    };
  };
  clan.core.vars.generators.flix-oauth2-proxy = {
    files."cookie-secret" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/cookie-secret"
    '';
  };

  services.nginx.virtualHosts = lib.mapAttrs (_: vhost) backends;
}
