{
  services.nginx.virtualHosts."grafana.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = "http://styx.r:3000";
    };
  };

  # Login via id.lassul.us (configs/monitoring/grafana-public.nix), only for
  # the users listed here. A public client with PKCE; its client id is in the
  # envFile and goes into the grafana-oidc var of styx.
  lass.zitadel.projects.grafana = {
    access = "declarative";
    users = [ "lass@lassul.us" ];
    apps.web = {
      redirectUris = [ "https://grafana.lassul.us/login/generic_oauth" ];
      authMethod = "none";
    };
  };
}
