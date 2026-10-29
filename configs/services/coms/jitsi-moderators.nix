{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.services.jitsi-meet) hostName;
in
{
  # token_affiliation makes users whose token says moderator owners of the
  # room; only the conference MUC needs it.
  options.services.prosody.muc = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule (
        { config, ... }:
        {
          config.extraModules = lib.mkIf (config.domain == "conference.${hostName}") [
            "token_affiliation"
          ];
        }
      )
    );
  };

  config = {
    # Moderators: users with a grant on the Zitadel project "jitsi" (console on
    # id.lassul.us) log in under Settings > Profile and are moderators in every
    # room. Everyone else joins anonymously and is never made moderator.
    lass.zitadel.projects.jitsi = {
      access = "managed";
      apps.web = {
        redirectUris = [ "https://${hostName}/oidc/callback" ];
        envFile.clientSecretVariable = "SECRET";
      };
    };
    clan.core.vars.generators.jitsi-jwt = {
      files.secret = { };
      runtimeInputs = [ pkgs.pwgen ];
      script = ''
        pwgen -s 64 1 | tr -d '\n' > $out/secret
      '';
    };
    systemd.services.jitsi-go-openid = {
      description = "${hostName} moderator login (id.lassul.us)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "zitadel-reconcile.service" ];
      after = [
        "network-online.target"
        "zitadel-reconcile.service"
      ];
      environment = {
        JITSI_URL = "https://${hostName}";
        JITSI_SUB = hostName;
        ISSUER_BASE_URL = "https://id.lassul.us";
        BASE_URL = "https://${hostName}/oidc";
        MODERATOR = "true";
      };
      script = ''
        JITSI_SECRET=$(cat "$CREDENTIALS_DIRECTORY/jwt-secret") exec ${
          lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.jitsi-go-openid
        }
      '';
      serviceConfig = {
        DynamicUser = true;
        EnvironmentFile = config.lass.zitadel.projects.jitsi.apps.web.envFile.path;
        LoadCredential = "jwt-secret:${config.clan.core.vars.generators.jitsi-jwt.files.secret.path}";
        Restart = "on-failure";
      };
    };
    # jitsi-go-openid listens on port 3001.
    services.nginx.virtualHosts.${hostName}.locations."/oidc/".proxyPass = "http://127.0.0.1:3001/";
    services.jitsi-meet.config.tokenAuthUrl = "https://${hostName}/oidc/authenticate?state={state}&room={room}";

    # Tokens are optional: without one the user is an anonymous guest.
    services.prosody.virtualHosts.${hostName}.extraConfig = lib.mkAfter ''
      authentication = "token"
      allow_empty_token = true
      app_id = "jitsi"
      app_secret = Credential("jitsi-jwt-secret")
    '';
    systemd.services.prosody.serviceConfig.LoadCredential = [
      "jitsi-jwt-secret:${config.clan.core.vars.generators.jitsi-jwt.files.secret.path}"
    ];
    services.prosody.package = pkgs.prosody.override {
      withExtraLuaPackages =
        p: with p; [
          basexx
          cjson
          inspect
          luaossl
        ];
    };
    # Otherwise the first guest in a room becomes its moderator.
    services.jicofo.config.jicofo.conference.enable-auto-owner = false;
  };
}
