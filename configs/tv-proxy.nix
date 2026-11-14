{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  port = config.lass.servicePorts.tv-proxy;
  styx = self.inputs.kartei.hosts.styx.nets.retiolum.ip4.addr;
  neoprism = self.inputs.kartei.hosts.neoprism.nets.retiolum.ip4.addr;
in
{
  # SOCKS5 proxy for tv.lassul.us on neoprism: YouTube refuses video
  # downloads from datacenter IPs, not from this residential line.
  lass.ports."1080" = "tv-proxy";

  systemd.services.tv-proxy = {
    description = "SOCKS5 proxy for tv.lassul.us";
    wantedBy = [ "multi-user.target" ];
    after = [ "tinc.retiolum.service" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.microsocks} -q -i ${styx} -p ${toString port}";
      DynamicUser = true;
      # binding fails until tinc has put the address on the interface
      Restart = "always";
      RestartSec = 5;
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
    };
  };

  networking.firewall.extraInputRules = ''
    iifname "retiolum" ip saddr ${neoprism} tcp dport ${toString port} accept
  '';
}
