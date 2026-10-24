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
    ../../configs/gg23/audio/room.nix
    ../../configs/monitoring/server.nix
    ../../configs/monitoring/grafana-public.nix
    ./backup.nix
  ];

  environment.systemPackages = with pkgs; [
    wol
    (writers.writeDashBin "wake-alien" ''
      ${wol}/bin/wol -h 10.42.0.255 10:65:30:68:83:a3
    '')
  ];

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
