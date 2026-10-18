{ config, pkgs, ... }:
let
  domain = "paperless.lassul.us";
  cfg = config.services.paperless;
  zitadelEnv = config.lass.zitadel.projects.paperless.apps.web.envFile.path;
  oidcEnv = "/run/paperless-oidc/oidc.env";
  paperlessServices = [
    "paperless-secret-key.service"
    "paperless-scheduler.service"
    "paperless-task-queue.service"
    "paperless-consumer.service"
    "paperless-web.service"
  ];
in
{
  clan.core.vars.generators.paperless-admin = {
    files."password" = { };
    runtimeInputs = with pkgs; [
      coreutils
      pwgen
    ];
    script = ''
      pwgen -s 32 1 | tr -d '\n' > "$out/password"
    '';
  };

  services.paperless = {
    enable = true;
    inherit domain;
    passwordFile = config.clan.core.vars.generators.paperless-admin.files."password".path;
    environmentFile = oidcEnv;
    settings = {
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_TIME_ZONE = "Europe/Berlin";
      PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      PAPERLESS_SOCIAL_AUTO_SIGNUP = true;
      # only the login form; API tokens and basic auth keep working
      PAPERLESS_DISABLE_REGULAR_LOGIN = true;
    };
  };

  # Zitadel (id.lassul.us) login, only for users with a grant on the project.
  # zitadel-reconcile writes the client id/secret to zitadelEnv.
  lass.zitadel.projects.paperless = {
    access = "declarative";
    users = [ "lass@lassul.us" ];
    apps.web = {
      redirectUris = [ "https://${domain}/accounts/oidc/zitadel/login/callback/" ];
      authMethod = "post";
    };
  };

  # Builds PAPERLESS_SOCIALACCOUNT_PROVIDERS with the client secret into
  # oidcEnv, the paperless environmentFile. Accounts are keyed by `sub`.
  systemd.services.paperless-oidc-env = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
    before = paperlessServices;
    requiredBy = paperlessServices;
    path = [ pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "paperless-oidc";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      UMask = "0077";
      EnvironmentFile = zitadelEnv;
    };
    script = ''
      providers=$(jq -nc '{openid_connect: {APPS: [{
        provider_id: "zitadel",
        name: "lassul.us ID",
        client_id: env.CLIENT_ID,
        secret: env.CLIENT_SECRET,
        settings: {
          server_url: "https://id.lassul.us",
          token_auth_method: "client_secret_post",
          uid_field: "sub"
        }
      }]}}')
      printf "PAPERLESS_SOCIALACCOUNT_PROVIDERS='%s'\n" "$providers" > ${oidcEnv}.tmp
      mv ${oidcEnv}.tmp ${oidcEnv}
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${cfg.address}:${toString cfg.port}";
      recommendedProxySettings = true;
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 100M;
      '';
    };
  };
}
