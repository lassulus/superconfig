# agentd-web (github:lassulus/agentd, cmd/agentd-web): web UI for agentd
# instances at agents.lassul.us, with login via id.lassul.us. The UI forwards
# the user's access token (a JWT) to each backend, which checks it against
# its own auth.oidc and users.
#
# Backends: a local agentd on neoprism (its own `agentd` user; omp needs a
# one-time login: `runuser -u agentd -- omp`, then /login). coaxmetal's
# agentd can be added to `backends` once it accepts these tokens too.
# Hermes (coaxmetal) drives the local agentd over retiolum
# (http://neoprism.r:8790) with an API token (agentd-neoprism-hermes-vars.nix).
{
  config,
  pkgs,
  self,
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
  imports = [
    self.inputs.agentd.nixosModules.default
    ../../agentd-neoprism-hermes-vars.nix
  ];

  lass.ports."8790" = "agentd";
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

  services.agentd = {
    enable = true;
    listen = "0.0.0.0:${toString agentdPort}";
    harnesses.omp.command = [
      "${pkgs.omp}/bin/omp"
      "acp"
    ];
    # Zitadel puts every client id of the project into the token's aud.
    auth.oidc = {
      inherit issuer;
      audienceFile = clientIdFile;
    };
    # lass's Zitadel user id: Zitadel access tokens have no email claim.
    users = [ "395780385822936760" ];
    auth.tokensFile = config.clan.core.vars.generators.agentd-neoprism-hermes.files.tokens.path;
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ agentdPort ];

  services.agentd-web = {
    enable = true;
    listen = "127.0.0.1:${toString webPort}";
    url = "https://${domain}";
    backends = [
      {
        name = "neoprism";
        url = "http://127.0.0.1:${toString agentdPort}";
      }
    ];
    oidc = {
      inherit issuer clientIdFile;
    };
  };

  # Both read the client id that reconcile writes.
  systemd.services.agentd = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
  };
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
