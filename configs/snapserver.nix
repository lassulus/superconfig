{ pkgs, ... }:
{
  services.snapserver = {
    enable = true;
    # openFirewall = true;
    settings.stream = {
      source = [
        "process://${pkgs.writers.writeDash "radio" ''
          exec ${pkgs.mpv}/bin/mpv http://radio.lassul.us/radio.ogg \
            --no-terminal \
            --audio-display=no \
            --audio-channels=stereo \
            --audio-samplerate=48000 \
            --audio-format=s16 \
            --ao=pcm \
            --ao-pcm-file=/dev/stdout
        ''}?name=radio"
        "pipe:///run/snapserver/snapfifo?name=styx"
      ];
    };
    http.enable = true;
    tcp.enable = true;
  };

  # Runs on the gg23 router: the LAN (int0) is trusted there
  # (configs/gg23.nix), et0 is the WAN and stays closed.
  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ 1780 ];

  # plays an iptv channel into the "styx" pipe stream
  environment.systemPackages = [
    (pkgs.writers.writeDashBin "iptv" ''
      set -efu
      ${pkgs.mpv}/bin/mpv \
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
}
