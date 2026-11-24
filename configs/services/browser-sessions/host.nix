# The backend and the session units on a session host (common.nix). The
# gateway on the proxy drives it over retiolum; the proxy also forwards the
# WebRTC ports here.
{
  config,
  lib,
  self,
  ...
}:
let
  common = import ./common.nix;
  name = config.networking.hostName;
  backend = common.backends.${name};
  nets = host: self.inputs.kartei.hosts.${host}.nets;
  retiolum = host: (nets host).retiolum.ip4.addr;
  bothFamilies = net: [
    net.ip4.addr
    net.ip6.addr
  ];
  port = block: i: backend.firstPort + 1 + block * backend.slots + i;
  slots = lib.genList (i: {
    neko = port 0 i;
    mcp = port 1 i;
    webrtc = port 2 i;
  }) backend.slots;
in
{
  imports = [
    ../../../tools/browser-sessions/module.nix
    ./token.nix
  ];

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
    listen = "0.0.0.0:${toString config.lass.servicePorts.browser-sessions}";
    tokenFile = config.clan.core.vars.generators.browser-sessions-backend.files.token.path;
    # both families, so clients on IPv6-only networks reach them as well
    publicAddresses = bothFamilies (nets common.proxy).internet;
    # proxy.nix forwards the UDP and TCP ports to these addresses
    privateAddresses = bothFamilies (nets name).retiolum;
    inherit slots;
  };

  # the backend only for the gateway; it checks the token as well
  networking.firewall.extraInputRules = ''
    iifname "retiolum" ip saddr ${retiolum common.proxy} tcp dport ${toString config.lass.servicePorts.browser-sessions} accept
  '';
  # WebRTC over UDP, and over TCP (ICE-TCP) for networks that block UDP;
  # only what the proxy forwards
  networking.firewall.interfaces.retiolum.allowedUDPPorts = map (s: s.webrtc) slots;
  networking.firewall.interfaces.retiolum.allowedTCPPorts = map (s: s.webrtc) slots;
}
