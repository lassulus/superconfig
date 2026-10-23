let
  domain = "nixcontalks.lassul.us";
  port = 8774;
  oauth2ProxyPort = 4181;
in
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # The confirmed talks (code and title) of the pretalx export
  # nixcon-2026_sessions.csv; only their codes can answer. type and recorded
  # (not do_not_record) come from the public schedule
  # (talks.nixcon.org/nixcon-2026/schedule/export/schedule.json); PWVQFK is
  # not on it. The results list only the recorded lightning/short/long talks.
  # The codes are no secret: they are in the public schedule's talk URLs.
  nixcontalks = pkgs.writeShellApplication {
    name = "nixcontalks";
    text = ''
      exec ${
        lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.nixcontalks
      } --talks ${./nixcontalks-talks.json} "$@"
    '';
  };
  oauth2Proxy = "http://127.0.0.1:${toString oauth2ProxyPort}";
  # Who may read the answers: verified addresses on id.lassul.us, and they
  # need the grant on the Zitadel project below as well.
  readers = [
    "lass@lassul.us"
    "picnoir@alternativebit.fr"
  ];

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
  # NixCon speakers get /<proposal_code>/yes and /<proposal_code>/no links
  # in a pretalx mail to release their talk video under CC BY-SA 4.0
  # (tools/nixcontalks); the no page takes an optional comment. The answers
  # and comments are on https://nixcontalks.lassul.us/results behind a login
  # on id.lassul.us, and on this machine as root with `nixcontalks results`.
  environment.systemPackages = [ nixcontalks ];

  systemd.services.nixcontalks = {
    description = "${domain} talk license consent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = hardening // {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe nixcontalks)
        "--database"
        "/var/lib/nixcontalks/answers.db"
        "serve"
        "--port"
        (toString port)
      ];
      StateDirectory = "nixcontalks";
    };
  };

  # Login for /results. services.oauth2-proxy is single-instance and taken
  # by assist.lassul.us (configs/hermes-proxy.nix), so this one is its own
  # unit, with its own Zitadel project, client and cookie.
  lass.zitadel.projects.nixcontalks = {
    access = "declarative";
    users = readers;
    apps.web = {
      redirectUris = [ "https://${domain}/oauth2/callback" ];
      envFile = {
        clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
        clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
      };
    };
  };
  systemd.services.nixcontalks-oauth2-proxy = {
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
        "--authenticated-emails-file=${pkgs.writeText "nixcontalks-readers" (lib.concatLines readers)}"
        "--cookie-name=_nixcontalks_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.lass.zitadel.projects.nixcontalks.apps.web.envFile.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.nixcontalks-oauth2-proxy.files."cookie-secret".path
      }";
    };
  };
  clan.core.vars.generators.nixcontalks-oauth2-proxy = {
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
        proxyPass = "http://127.0.0.1:${toString port}";
        extraConfig = ''
          proxy_set_header Host $host;
          client_max_body_size 40k;
        '';
      };
      "= /results" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        extraConfig = ''
          auth_request /oauth2/auth;
          error_page 401 = @login;
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
      "@login".return = "307 /oauth2/start?rd=$request_uri";
    };
  };
}
