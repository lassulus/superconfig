# The gateway and the session units on a backend (common.nix). It is only
# reachable over retiolum: the proxy forwards the page and the WebRTC ports.
{
  config,
  lib,
  self,
  ...
}:
let
  common = import ./common.nix;
  backend = common.backends.${config.networking.hostName};
  port = block: i: backend.firstPort + 1 + block * backend.slots + i;
  slots = lib.genList (i: {
    neko = port 0 i;
    mcp = port 1 i;
    webrtc = port 2 i;
  }) backend.slots;
in
{
  imports = [ ../../../tools/browser-sessions/module.nix ];

  lass.ports = {
    ${toString backend.firstPort} = "browser-sessions";
  }
  // lib.listToAttrs (
    lib.concatLists (
      lib.imap0 (
        i: slot:
        lib.mapAttrsToList (
          kind: p: lib.nameValuePair (toString p) "browser-session-${kind}-${toString i}"
        ) slot
      ) slots
    )
  );

  services.browser-sessions = {
    enable = true;
    url = "https://${common.domain}";
    listen = "0.0.0.0:${toString config.lass.servicePorts.browser-sessions}";
    inherit (common) idleTimeout;
    oidc = {
      issuer = "https://id.lassul.us";
      clientIdFile = config.clan.core.vars.generators.browser-sessions-oidc.files.client-id.path;
    };
    publicAddress = self.inputs.kartei.hosts.${common.proxy}.nets.internet.ip4.addr;
    # proxy.nix forwards the UDP ports to this address
    privateAddress = self.inputs.kartei.hosts.${config.networking.hostName}.nets.retiolum.ip4.addr;
    inherit slots;
  };

  networking.firewall.interfaces.retiolum = {
    allowedTCPPorts = [ config.lass.servicePorts.browser-sessions ];
    allowedUDPPorts = map (s: s.webrtc) slots;
  };

  # Zitadel app browser-sessions/web (proxy.nix)
  clan.core.vars.generators.browser-sessions-oidc = {
    files.client-id = { };
    prompts.client-id.description = "Client id of the Zitadel app browser-sessions/web (CLIENT_ID in /var/lib/zitadel-apps/browser-sessions-web.env on the Zitadel host)";
    script = ''
      cp "$prompts"/client-id "$out"/client-id
    '';
  };
}
