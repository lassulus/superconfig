{ config, ... }:
{
  imports = [ ./module.nix ];
  clan.hedgedoc.domain = "pad.lassul.us";

  # GitHub login (https://github.com/settings/applications/2352617)
  clan.core.vars.generators.hedgedoc-github-auth = {
    files."hedgedoc.env" = { };
    prompts."hedgedoc.env" = {
      description = ''
        goto https://github.com/settings/applications/2352617 and paste the data in the following format:
        GITHUB_CLIENT_ID=...
        GITHUB_CLIENT_SECRET=...
      '';
      type = "multiline";
    };
  };

  # Zitadel (id.lassul.us) OIDC login, offered alongside GitHub, open to every
  # registered user. zitadel-reconcile creates the app and writes its client
  # id/secret into the env file below.
  lass.zitadel.projects.pad = {
    access = "public";
    apps.hedgedoc = {
      redirectUris = [ "https://pad.lassul.us/auth/oauth2/callback" ];
      # HedgeDoc sends the secret in the token request body.
      authMethod = "post";
      envFile = {
        owner = "hedgedoc";
        clientIdVariable = "CMD_OAUTH2_CLIENT_ID";
        clientSecretVariable = "CMD_OAUTH2_CLIENT_SECRET";
      };
    };
  };
  services.hedgedoc.settings.oauth2 = {
    providerName = "lassul.us ID";
    authorizationURL = "https://id.lassul.us/oauth/v2/authorize";
    tokenURL = "https://id.lassul.us/oauth/v2/token";
    userProfileURL = "https://id.lassul.us/oidc/v1/userinfo";
    scope = "openid email profile";
    # sub, not the freely chosen username: HedgeDoc shares one user table with GitHub logins.
    userProfileIdAttr = "sub";
    userProfileUsernameAttr = "preferred_username";
    userProfileDisplayNameAttr = "name";
    userProfileEmailAttr = "email";
  };

  # GitHub session-secret env comes from module.nix; append both external-auth
  # env files here (systemd merges the EnvironmentFile lists).
  systemd.services.hedgedoc = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
    serviceConfig.EnvironmentFile = [
      config.clan.core.vars.generators.hedgedoc-github-auth.files."hedgedoc.env".path
      config.lass.zitadel.projects.pad.apps.hedgedoc.envFile.path
    ];
  };
}
