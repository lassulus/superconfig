{ lib, pkgs, ... }:
{
  # vodafone router drifts out of time
  services.timesyncd.servers = [
    "0.pool.ntp.org"
    "1.pool.ntp.org"
    "2.pool.ntp.org"
    "3.pool.ntp.org"
  ];
  systemd.network.networks."50-et0" = {
    matchConfig.Name = "et0";
    DHCP = "yes";
    linkConfig = {
      RequiredForOnline = "routable";
    };
    networkConfig = {
      IPv6AcceptRA = true;
      IPv6Forwarding = true;
    };
  };
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
  systemd.network.networks."10-int0" = {
    name = "int0";
    address = [
      "10.42.0.1/24"
      "fd42:7d6a::1/64"
    ];
    networkConfig = {
      IPv4Forwarding = true;
      IPv6Forwarding = true;
      ConfigureWithoutCarrier = true;
      DHCPServer = "yes";
      IPv6SendRA = true;
    };
    # announce ourselves (dnsmasq) as resolver, so *.gg23 resolves for clients
    dhcpServerConfig = {
      EmitDNS = true;
      DNS = "_server_address";
      EmitDomain = true;
      Domain = "gg23";
    };
    ipv6SendRAConfig = {
      EmitDNS = true;
      DNS = [ "fd42:7d6a::1" ];
      EmitDomains = true;
      Domains = [ "gg23" ];
    };
    ipv6Prefixes = [
      {
        ipv6PrefixConfig = {
          Prefix = "fd42:7d6a::/64";
        };
      }
    ];
    dhcpServerStaticLeases = [
      {
        # printer
        dhcpServerStaticLeaseConfig = {
          Address = "10.42.0.4";
          MACAddress = "94:dd:f8:23:c5:ac";
        };
      }
      {
        # firetv
        dhcpServerStaticLeaseConfig = {
          Address = "10.42.0.11";
          MACAddress = "84:28:59:f0:d2:a8";
        };
      }
      {
        # styx (et0), ex-router: snapserver, mosquitto, mycelium peer
        dhcpServerStaticLeaseConfig = {
          Address = "10.42.0.3";
          MACAddress = "3c:7c:3f:7e:e2:39";
        };
      }
      # {
      #   dhcpServerStaticLeaseConfig = {
      #     Address = "10.42.0.10";
      #     MACAddress = "ea:4d:12:94:74:2a";
      #   };
      # }
      {
        dhcpServerStaticLeaseConfig = {
          Address = "10.42.0.10";
          MACAddress = "fe:fe:fe:fe:fe:fe";
        };
      }
    ];
  };
  networking.networkmanager.unmanaged = [ "int0" ];
  networking.firewall.trustedInterfaces = [ "int0" ];
  # ICMPv6 is forwarded by nixos-fw's forward chain already.
  networking.firewall.extraForwardRules = ''
    iifname "int0" accept
    oifname "int0" accept
  '';
  networking.nftables.tables.gg23 = {
    family = "inet";
    content = ''
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.42.0.0/24 masquerade
        ip6 saddr fd42:7d6a::/64 masquerade
      }
    '';
  };

  networking.domain = "gg23";

  networking.useHostResolvConf = false;
  services.resolved.settings.Resolve.DNSStubListener = "no";
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;

    settings = {
      local = "/gg23/";
      domain = "gg23";
      expand-hosts = true;
      listen-address = "10.42.0.1,10.233.0.1";
      interface = "int0";
    };
  };

  # dnsmasq serves /etc/hosts to the LAN; NixOS maps our own fqdn to
  # 127.0.0.2 there, which clients would then try to reach. extraHosts in
  # configs/default.nix already has the real 10.42.0.1 entry.
  networking.hosts."127.0.0.2" = lib.mkForce [ ];

  environment.systemPackages = [
    (pkgs.writers.writeDashBin "restart_router" ''
      ${pkgs.mosquitto}/bin/mosquitto_pub -h 10.42.0.3 -t 'cmnd/router/POWER' -u gg23 -P gg23-mqtt -m OFF
      sleep 2
      ${pkgs.mosquitto}/bin/mosquitto_pub -h 10.42.0.3 -t 'cmnd/router/POWER' -u gg23 -P gg23-mqtt -m ON
    '')
  ];
}
