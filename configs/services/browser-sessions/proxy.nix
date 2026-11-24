# The public side of the browser sessions (common.nix), as
# configs/atlas-sunshine-forward.nix does it for Moonlight: the gateway
# runs here behind nginx and drives the backends over retiolum, and every
# backend's WebRTC ports (UDP and TCP) are forwarded to it; its neko
# announces this host's address. Browsers that reach neither get the TURN
# server here (configs/services/coms/coturn.nix), which relays to that
# address too. The zone's wildcard already points the name here.
{
  config,
  lib,
  self,
  ...
}:
let
  common = import ./common.nix;
  backends = lib.mapAttrsToList (name: b: {
    inherit name;
    inherit (b) firstPort slots;
    addr = self.inputs.kartei.hosts.${name}.nets.retiolum.ip4.addr;
    webrtc = lib.genList (i: b.firstPort + 1 + 2 * b.slots + i) b.slots;
  }) common.backends;
  app = config.lass.zitadel.projects.browser-sessions.apps.web;
in
{
  imports = [
    ../../../tools/browser-sessions/module.nix
    ./token.nix
    ../coms/coturn.nix
  ];

  lass.ports = {
    ${toString common.gatewayPort} = "browser-sessions-gateway";
  }
  // lib.listToAttrs (
    lib.concatMap (
      b:
      lib.imap0 (
        i: p: lib.nameValuePair (toString p) "browser-session-${b.name}-webrtc-${toString i}"
      ) b.webrtc
    ) backends
  );

  # Who may create sessions: the users an admin granted this project in the
  # Zitadel console (this is the Zitadel host). A public client with PKCE.
  lass.zitadel.projects.browser-sessions = {
    access = "managed";
    apps.web = {
      redirectUris = [ "https://${common.domain}/callback" ];
      authMethod = "none";
    };
  };

  services.browser-sessions-gateway = {
    enable = true;
    url = "https://${common.domain}";
    listen = "127.0.0.1:${toString config.lass.servicePorts.browser-sessions-gateway}";
    tokenFile = config.clan.core.vars.generators.browser-sessions-backend.files.token.path;
    oidc = {
      issuer = "https://id.lassul.us";
      inherit (app) clientIdFile;
    };
    inherit (common) stopAfterMinutes;
    turn = {
      urls =
        let
          host = config.services.coturn.realm;
          port = toString config.lass.servicePorts.coturn;
        in
        [
          "turn:${host}:${port}?transport=udp"
          "turn:${host}:${port}?transport=tcp"
          # through nginx's SNI split (coturn.nix), for networks that let
          # only HTTPS out
          "turns:${host}:${toString config.lass.servicePorts.nginx-https}?transport=tcp"
        ];
      secretFile = config.clan.core.vars.generators.coturn.files.secret.path;
    };
    backends = lib.listToAttrs (
      map (
        b:
        lib.nameValuePair b.name {
          url = "http://${b.addr}:${toString b.firstPort}";
          inherit (b) slots;
        }
      ) backends
    );
  };
  # reads the client id that reconcile writes
  systemd.services.browser-sessions-gateway = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
  };

  # Links carry the session token in the path: the access log masks it and
  # leaves out the query and the referer. nginx's error lines quote the
  # request unmasked, so this name logs only critical ones. The log format
  # has to come before the vhosts that use it.
  services.nginx.commonHttpConfig = ''
    map $uri $browser_sessions_uri {
      "~^/s/[^/]+(?<rest>.*)$" "/s/***$rest";
      default $uri;
    }
    log_format browser_sessions '$remote_addr - $remote_user [$time_local] '
      '"$request_method $browser_sessions_uri $server_protocol" $status $body_bytes_sent '
      '"$http_user_agent"';
  '';
  services.nginx.virtualHosts.${common.domain} = {
    enableACME = true;
    forceSSL = true;
    extraConfig = ''
      access_log /var/log/nginx/access.log browser_sessions;
      error_log stderr crit;
    '';
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.lass.servicePorts.browser-sessions-gateway}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      # MCP answers and neko's API stream
      extraConfig = "proxy_buffering off;";
    };
  };

  services.browser-sessions-forward = {
    enable = true;
    interface = "retiolum";
    backends = lib.listToAttrs (
      map (
        b:
        lib.nameValuePair b.name {
          addresses = [ b.addr ];
          ports = b.webrtc;
        }
      ) backends
    );
  };
}
