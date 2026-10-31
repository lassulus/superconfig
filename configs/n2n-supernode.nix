{ pkgs, ... }:
let
  port = 7654;
in
{
  lass.ports.${toString port} = "n2n-supernode";

  systemd.services.n2n-supernode = {
    description = "n2n supernode";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      # -F sets the supernode federation name; n2n prepends '*', so this
      # becomes the federation community '*krebs' (avoids the default
      # '*Federation'). Only affects supernode-to-supernode federation, not
      # the community (-c) edges use.
      ExecStart = "${pkgs.n2n}/bin/supernode -f -p ${toString port} -F krebs";
      Restart = "always";
      RestartSec = 5;
      # supernode insists on dropping privileges to nobody (uid/gid 65534) itself
      # and aborts if the setuid() fails, so it must start as root -- DynamicUser
      # leaves it already-unprivileged and the drop fails (exit 1).
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };

  # UDP is the main n2n protocol; TCP is the supernode's "aux" listener,
  # used by edges started with -S2 when their network blocks UDP.
  networking.firewall.allowedUDPPorts = [ port ];
  networking.firewall.allowedTCPPorts = [ port ];
}
