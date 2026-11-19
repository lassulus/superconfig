let
  domain = "continuum.lassul.us";
  oauth2ProxyPort = 4185;
  socketDirectory = "continuum";
  socket = "/run/${socketDirectory}/api.sock";
  userHeader = "X-Continuum-User";
in
{
  config,
  lib,
  pkgs,
  ...
}:
let
  oauth2Proxy = "http://127.0.0.1:${toString oauth2ProxyPort}";
  # a verified address on id.lassul.us; continuum takes it as the user's name
  owner = "lass@lassul.us";

  # loopback stays for htpasswd and tokens; only the socket, nginx's alone, may name a user
  nodeSettings = (pkgs.formats.json { }).generate "continuum-dashboard.json" {
    bind-addr = [
      "127.0.0.1:${toString config.lass.servicePorts.continuum}"
      "unix:${socket}"
    ];
    user-header = userHeader;
    trusted-proxies = [ "unix" ];
  };

  hardening = {
    DynamicUser = true;
    Restart = "on-failure";
    CapabilityBoundingSet = "";
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectHome = true;
    ProtectSystem = "strict";
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
in
{
  lass.ports.${toString oauth2ProxyPort} = "continuum-oauth2-proxy";

  # the socket is the node's group's (mode 0660), so nginx joins that group
  users.groups.continuum-api = { };
  users.users.${config.services.nginx.user}.extraGroups = [ "continuum-api" ];
  systemd.services.continuum.serviceConfig = {
    LoadCredential = [ "dashboard.json:${nodeSettings}" ];
    # static, beside the dynamic user: one named as the user would clash with its dynamic group
    Group = "continuum-api";
    RuntimeDirectory = socketDirectory;
    RuntimeDirectoryMode = "0750";
  };

  # services.oauth2-proxy is single-instance and taken by assist.lassul.us
  lass.zitadel.projects.continuum = {
    access = "declarative";
    users = [ owner ];
    apps.web = {
      redirectUris = [ "https://${domain}/oauth2/callback" ];
      envFile = {
        clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
        clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
      };
    };
  };
  systemd.services.continuum-oauth2-proxy = {
    description = "${domain} login (id.lassul.us)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "zitadel-reconcile.service" ];
    after = [
      "network-online.target"
      "zitadel-reconcile.service"
    ];
    serviceConfig = hardening // {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.oauth2-proxy)
        "--provider=oidc"
        "--oidc-issuer-url=https://id.lassul.us"
        "--redirect-url=https://${domain}/oauth2/callback"
        "--http-address=${oauth2Proxy}"
        "--authenticated-emails-file=${pkgs.writeText "continuum-dashboard-users" owner}"
        "--set-xauthrequest=true"
        "--cookie-name=_continuum_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.lass.zitadel.projects.continuum.apps.web.envFile.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.continuum-oauth2-proxy.files."cookie-secret".path
      }";
    };
  };
  clan.core.vars.generators.continuum-oauth2-proxy = {
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
        recommendedProxySettings = true;
        proxyPass = "http://unix:${socket}";
        # proxy_set_header replaces whatever the client sent as the user header
        extraConfig = ''
          auth_request /oauth2/auth;
          error_page 401 = @login;
          auth_request_set $continuum_user $upstream_http_x_auth_request_email;
          proxy_set_header ${userHeader} $continuum_user;
          # the dashboard streams Server-Sent Events
          proxy_buffering off;
        '';
      };
      "/oauth2/" = {
        recommendedProxySettings = true;
        proxyPass = oauth2Proxy;
      };
      "= /oauth2/auth" = {
        recommendedProxySettings = true;
        proxyPass = oauth2Proxy;
        extraConfig = ''
          proxy_pass_request_body off;
          proxy_set_header Content-Length "";
        '';
      };
      # the node serves nothing at /; the dashboard is the page people open
      "= /".return = "302 /admin/dashboard";
      "@login".return = "307 /oauth2/start?rd=$request_uri";
    };
  };
}
