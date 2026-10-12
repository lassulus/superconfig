{
  pkgs,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/pipewire.nix
    ../../configs/yellow-mounts/samba.nix
    ../../configs/n8n.nix
    ../../configs/green-host.nix
    ../../configs/syncthing.nix
    ../../configs/ppp/umts-stick.nix
    ../../configs/snapserver.nix
    ../../configs/snapclient.nix
    ../../configs/consul.nix
  ];

  environment.systemPackages = with pkgs; [
    wol
    (writers.writeDashBin "wake-alien" ''
      ${wol}/bin/wol -h 10.42.0.255 10:65:30:68:83:a3
    '')
    (writers.writeDashBin "iptv" ''
      set -efu
      /run/current-system/sw/bin/mpv \
        --audio-display=no --audio-channels=stereo \
        --audio-samplerate=48000 --audio-format=s16 \
        --ao-pcm-file=/run/snapserver/snapfifo --ao=pcm \
        --audio-delay=-1 \
        --playlist=https://iptv-org.github.io/iptv/index.nsfw.m3u \
        --idle=yes \
        --input-ipc-server=/tmp/mpv.ipc \
        "$@"
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
