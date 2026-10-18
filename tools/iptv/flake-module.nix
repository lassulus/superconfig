{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # Listen to TV channels from the iptv-org playlist, audio only, on this
      # machine's default output. mpv's keys switch channels (< and >).
      packages.iptv =
        (pkgs.writeShellApplication {
          name = "iptv";
          runtimeInputs = [ pkgs.mpv ];
          text = ''
            exec mpv \
              --no-video \
              --audio-display=no \
              --playlist=https://iptv-org.github.io/iptv/index.m3u \
              "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
