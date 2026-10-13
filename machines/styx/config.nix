{
  pkgs,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/pipewire.nix
    ../../configs/n8n.nix
    ../../configs/green-host.nix
    ../../configs/syncthing.nix
    ../../configs/ppp/umts-stick.nix
    ../../configs/snapclient.nix
    ../../configs/consul.nix
    ../../configs/monitoring/server.nix
  ];

  environment.systemPackages = with pkgs; [
    wol
    (writers.writeDashBin "wake-alien" ''
      ${wol}/bin/wol -h 10.42.0.255 10:65:30:68:83:a3
    '')
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
  services.smokeping = {
    enable = true;
    host = null;
    targetConfig = ''
      probe = FPing
      menu = top
      title = top

      + Local
      menu = Local
      title = Local Network
      ++ LocalMachine
      menu = Local Machine
      title = This host
      host = localhost

      + Internet
      menu = internet
      title = internet

      ++ CloudflareDNS
      menu = Cloudflare DNS
      title = Cloudflare DNS server
      host = 1.1.1.1

      ++ GoogleDNS
      menu = Google DNS
      title = Google DNS server
      host = 8.8.8.8

      + retiolum
      menu = retiolum
      title = retiolum

      ++ gum
      menu = gum.r
      title = gum.r
      host = gum.r

      ++ ni
      menu = ni.r
      title = ni.r
      host = ni.r

      ++ neoprism
      menu = neoprism.r
      title = neoprism.r
      host = neoprism.r
    '';
  };

  # for usb internet
  hardware.usbWwan.enable = true;

  swapDevices = [
    {
      device = "/swapfile";
      size = 8192;
    }
  ];
  services.earlyoom.enable = true;
}
