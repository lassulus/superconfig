let
  domain = "docs.c3gsm.de";
  oauth2ProxyPort = 4183;
  oauth2Proxy = "http://127.0.0.1:${toString oauth2ProxyPort}";
  issuer = "https://auth.0xc0fee.dev";
in
{
  config,
  lib,
  pkgs,
  ...
}:
{
  lass.ports.${toString oauth2ProxyPort} = "docs-oauth2-proxy";

  clan.core.vars.generators.docs-oauth2-client = {
    files.env = { };
    prompts.client_id = {
      description = "OIDC client ID for ${domain} at ${issuer} (callback: https://${domain}/oauth2/callback)";
      persist = true;
    };
    prompts.client_secret = {
      description = "OIDC client secret for ${domain} at ${issuer}";
      type = "hidden";
      persist = true;
    };
    script = ''
      {
        printf 'OAUTH2_PROXY_CLIENT_ID=%s\n' "$(cat "$prompts"/client_id)"
        printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "$(cat "$prompts"/client_secret)"
      } > "$out/env"
    '';
  };

  systemd.services.docs-oauth2-proxy = {
    description = "${domain} login (${issuer})";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.oauth2-proxy)
        "--provider=oidc"
        "--oidc-issuer-url=${issuer}"
        "--redirect-url=https://${domain}/oauth2/callback"
        "--http-address=${oauth2Proxy}"
        "--email-domain=*"
        "--cookie-name=_docs_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.clan.core.vars.generators.docs-oauth2-client.files.env.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.docs-oauth2-proxy.files."cookie-secret".path
      }";
      DynamicUser = true;
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };

  clan.core.vars.generators.docs-oauth2-proxy = {
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
    forceSSL = true;
    enableACME = true;
    root = "/srv/http/docs.c3gsm.de";
    extraConfig = ''
      auth_request /oauth2/auth;
      error_page 401 = @login;
    '';
    locations = {
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

  services.nginx.virtualHosts."c3gsm.de" = {
    forceSSL = true;
    enableACME = true;
    root = "/srv/http/c3gsm.de/wwwroot";
    locations."/" = {
      tryFiles = "$uri $uri/ $uri.html =404";
    };
  };

  systemd.services."c3gsm-website-cleanup-preview" = {
    script = ''
      set -eu
      ${pkgs.findutils}/bin/find \
        /srv/http/c3gsm.de/wwwroot/pre \
        -mindepth 1 \
        -ctime +7 \
        -delete
    '';
    startAt = "daily";
    serviceConfig = {
      Type = "oneshot";
      User = "c3gsm";
    };
  };

  users.users.c3gsm-docs = {
    isNormalUser = true;
    home = "/srv/http/docs.c3gsm.de";
    createHome = true;
    homeMode = "750";
    useDefaultShell = true;
    group = "nginx";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAlW1fvCrVXhVH/z76fXBWYR/qyecYTE9VOOkFLJ6OwG user@osmocom-dev"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBV1+1YcOyLA16i9tPDMZsdMKNfVkh884QQGQkHy7L7t gitlab-deployment"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDrhZNSJ7Yqr+DuwQLSRdZXcEPs0cnH87T+6tg4dbzZSVuxEWuGPeo1SR7XU0l7Ut4n/HhBLu1Lw+BeIsH2FbbeLP5QnYEWaCDpaQxy8SYb+6tn7x6GxG0at4hrdk3vm+UAltqhBQLvpZGfLEvGr+E1e0GfQq0y2MU6glqzmOP43h8XcJ7htTGkduuO947K7WTcv5QaN7Mc1uR+a1EvJ2N+t09x1Hl0sm6MwJvPv88AzrmmOWfikJre7XQspmb5XpecNzSAPZ187MQj8XTqzky4RQFo76/yzn++5XCdjJNGOiJb+W5ob+CXJqdwdBZGyo7n4ZNMfqNV3H1Me3XMunjwwnKczO6nN9iQzTQyjqeMsz4p51iz1ccjXvnKgo5NTff+FwU643LYNH3y9WdzqgLkoGR5R7Dy05qSOOQ2dGPGZi18h2iYTz5/OjjJsU+0bIaY0YGkIbVRhFDvToHew09VLSd7nWOqGIrnINwNsPYc7THOn0ys+RTcMPlxE92lIHaKBUl/+a+q5IGzwMEJfY9kuo2GtEiwfe1gWo7nX4O0hE/B1aqbQ9umrVo/CTNvqOHI+tr/LwQYoyWRFlKEZNqFtOdyw6lf+g4CvmupIct9IEYWMLi7L03i6vhnBUf8aQuguC3FCOC3lBdo2hecw29i8j0F87a1rsVRFm2CDHsOQQ== openpgp:0xB565044B"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAv5PvopW5HjYQQeuhKV4Q9+/hR3aNRwIvYJ86yTG4yP c3gsmdocs_gitlab_ci"
    ];
  };

  users.users.c3gsm = {
    isNormalUser = true;
    home = "/srv/http/c3gsm.de";
    createHome = true;
    homeMode = "750";
    useDefaultShell = true;
    group = "nginx";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAlW1fvCrVXhVH/z76fXBWYR/qyecYTE9VOOkFLJ6OwG user@osmocom-dev"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBV1+1YcOyLA16i9tPDMZsdMKNfVkh884QQGQkHy7L7t gitlab-deployment"
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDrhZNSJ7Yqr+DuwQLSRdZXcEPs0cnH87T+6tg4dbzZSVuxEWuGPeo1SR7XU0l7Ut4n/HhBLu1Lw+BeIsH2FbbeLP5QnYEWaCDpaQxy8SYb+6tn7x6GxG0at4hrdk3vm+UAltqhBQLvpZGfLEvGr+E1e0GfQq0y2MU6glqzmOP43h8XcJ7htTGkduuO947K7WTcv5QaN7Mc1uR+a1EvJ2N+t09x1Hl0sm6MwJvPv88AzrmmOWfikJre7XQspmb5XpecNzSAPZ187MQj8XTqzky4RQFo76/yzn++5XCdjJNGOiJb+W5ob+CXJqdwdBZGyo7n4ZNMfqNV3H1Me3XMunjwwnKczO6nN9iQzTQyjqeMsz4p51iz1ccjXvnKgo5NTff+FwU643LYNH3y9WdzqgLkoGR5R7Dy05qSOOQ2dGPGZi18h2iYTz5/OjjJsU+0bIaY0YGkIbVRhFDvToHew09VLSd7nWOqGIrnINwNsPYc7THOn0ys+RTcMPlxE92lIHaKBUl/+a+q5IGzwMEJfY9kuo2GtEiwfe1gWo7nX4O0hE/B1aqbQ9umrVo/CTNvqOHI+tr/LwQYoyWRFlKEZNqFtOdyw6lf+g4CvmupIct9IEYWMLi7L03i6vhnBUf8aQuguC3FCOC3lBdo2hecw29i8j0F87a1rsVRFm2CDHsOQQ== openpgp:0xB565044B"
    ];
  };
}
