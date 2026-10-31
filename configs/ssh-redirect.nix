# Public ssh is on 45621; port 22 itself only answers on the VPNs (and lo).
{ config, ... }:
{
  # not a listener, but nothing else can be reached on it
  lass.ports."45621" = "ssh-redirect";
  networking.nftables.tables.ssh-redirect = {
    family = "inet";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${toString config.lass.servicePorts.ssh-redirect} redirect to :22
      }
      chain output {
        type nat hook output priority dstnat; policy accept;
        oifname "lo" tcp dport ${toString config.lass.servicePorts.ssh-redirect} redirect to :22
      }
      # Runs before nixos-fw, which accepts 22 everywhere. Connections that
      # came in on 45621 have been redirected to 22 already, so match the
      # port the client asked for. tcp dport 22 spares connections to 22
      # that got redirected elsewhere (the tangled knot on neoprism).
      chain input {
        type filter hook input priority filter - 1; policy accept;
        ct state new tcp dport 22 ct original proto-dst 22 iifname != { "lo", "retiolum", "wiregrill" } reject with tcp reset
      }
    '';
  };
}
