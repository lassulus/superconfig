# agentd-web (github:lassulus/agentd, cmd/agentd-web): web UI for agentd
# instances at agents.lassul.us, with login via id.lassul.us. The UI forwards
# the user's access token (a JWT) to each backend, which checks it against
# its own auth.oidc and users (oidc.nix).
# The agentd-web options come with the agentd module that default.nix
# imports; importing it here again would define its
# package defaults twice.
#
# Backends: the local agentd (default.nix) and the other agentd hosts over
# retiolum.
{
  config,
  ...
}:
let
  domain = "agents.lassul.us";
  agentdPort = config.lass.servicePorts.agentd;
  webPort = config.lass.servicePorts.agentd-web;
  clientIdFile = config.lass.zitadel.projects.agentd.apps.web.clientIdFile;
  issuer = "https://id.lassul.us";
in
{
  lass.ports."8792" = "agentd-web";

  # Only lass can log in (declarative grant), and his tokens are JWTs so the
  # backends can verify them.
  lass.zitadel.projects.agentd = {
    access = "declarative";
    users = [ "lass@lassul.us" ];
    apps.web = {
      redirectUris = [ "https://${domain}/callback" ];
      authMethod = "none";
      accessTokenType = "jwt";
    };
  };

  services.agentd-web = {
    enable = true;
    listen = "127.0.0.1:${toString webPort}";
    url = "https://${domain}";
    backends = [
      {
        name = "neoprism";
        url = "http://127.0.0.1:${toString agentdPort}";
      }
      {
        name = "coaxmetal";
        url = "http://coaxmetal.r:8791";
      }
    ];
    oidc = {
      inherit issuer clientIdFile;
    };
  };

  # reads the client id that reconcile writes
  systemd.services.agentd-web = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      recommendedProxySettings = true;
      proxyPass = "http://127.0.0.1:${toString webPort}";
      # live transcripts are server-sent events
      extraConfig = "proxy_buffering off;";
    };
  };
}
