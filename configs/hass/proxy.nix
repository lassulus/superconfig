{
  services.nginx.virtualHosts."hass.lassul.us" = {
    enableACME = true;
    addSSL = true;
    locations."/" = {
      recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = "http://acheron.r:8123";
    };
  };

  # Login via id.lassul.us (auth_oidc, configs/hass/oidc.nix), only for users
  # an admin gave a user grant on the project in the console. A public client
  # with PKCE; its client id is in the envFile and goes into the hass-oidc var
  # of acheron.
  lass.zitadel.projects.hass = {
    access = "managed";
    apps.web = {
      redirectUris = [ "https://hass.lassul.us/auth/oidc/callback" ];
      authMethod = "none";
    };
  };
}
