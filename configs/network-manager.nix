{
  self,
  pkgs,
  ...
}:
{

  networking.networkmanager = {
    enable = true;
    unmanaged = [
      "docker*"
      "vboxnet*"
    ];
  };

  # NetworkManager is the sole wifi manager on NM hosts. The base
  # config enables systemd-networkd (networking.useNetworkd), which otherwise
  # ALSO runs a DHCP client on the wifi through the auto-generated
  # 40-<iface>.network. Two DHCP clients on one link fight over the lease and
  # routes and drop the connection every few minutes (networkd logged a
  # "DHCP lease lost"/"acquired" cycle on the wifi every ~10-20 min). Match
  # by Type=wlan (not interface name) and sort before 40-* so networkd leaves
  # every wifi link to NetworkManager, immune to the wlp192s0<->wlan0 rename.
  systemd.network.networks."10-wifi-unmanaged" = {
    matchConfig.Type = "wlan";
    linkConfig.Unmanaged = true;
  };
  # A host on cable and wifi in the same LAN: by default Linux answers ARP for
  # any local address on any interface, so the wifi answers NetworkManager's
  # address conflict probe for the cable's IP. NM then sees a conflict and
  # drops the cable's LAN route, and LAN traffic goes over wifi. Answer ARP
  # only on the interface that owns the address.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
  };
  systemd.services.NetworkManager-wait-online.enable = false;
  users.users.mainUser = {
    extraGroups = [ "networkmanager" ];
    packages = with pkgs; [
      gnome-keyring
      dconf
    ];
  };
  environment.systemPackages = [
    self.packages.${pkgs.system}.nm-dmenu
    pkgs.wirelesstools
  ];
}
