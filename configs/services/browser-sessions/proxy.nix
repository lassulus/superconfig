# The public side of the browser sessions (common.nix), as
# configs/atlas-sunshine-forward.nix does it for Moonlight: the gateway
# runs here behind nginx and drives the backends over retiolum, and every
# backend's WebRTC UDP ports are forwarded to it; its neko announces this
# host's address. The zone's wildcard already points the name here.
{
  config,
  lib,
  self,
  ...
}:
let
  common = import ./common.nix;
  backends = lib.mapAttrsToList (name: b: rec {
    inherit name;
    inherit (b) firstPort slots;
    addr = self.inputs.kartei.hosts.${name}.nets.retiolum.ip4.addr;
    udp = lib.genList (i: b.firstPort + 1 + 2 * b.slots + i) b.slots;
    udpSet = "{ ${lib.concatMapStringsSep ", " toString udp} }";
  }) common.backends;
  app = config.lass.zitadel.projects.browser-sessions.apps.web;
in
{
  imports = [
    ../../../tools/browser-sessions/module.nix
    ./token.nix
  ];

  lass.ports = {
    ${toString common.gatewayPort} = "browser-sessions-gateway";
  }
  // lib.listToAttrs (
    lib.concatMap (
      b:
      lib.imap0 (
        i: p: lib.nameValuePair (toString p) "browser-session-${b.name}-webrtc-${toString i}"
      ) b.udp
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

  networking.nftables.tables.browser-sessions = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ${lib.concatMapStringsSep "\n  " (
          b: ''iifname != "retiolum" fib daddr type local udp dport ${b.udpSet} dnat to ${b.addr}''
        ) backends}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # the host answers the proxy over retiolum, not the client directly
        ${lib.concatMapStringsSep "\n  " (
          b: "ip daddr ${b.addr} udp dport ${b.udpSet} ct status dnat masquerade"
        ) backends}
      }
    '';
  };
  networking.firewall.extraForwardRules = lib.concatMapStrings (
    b: "ip daddr ${b.addr} udp dport ${b.udpSet} ct status dnat accept\n"
  ) backends;
}
