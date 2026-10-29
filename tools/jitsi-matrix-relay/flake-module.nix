{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # Chat relay between a Jitsi Meet room and a Matrix room
      # (configs/services/coms/jitsi-space.nix).
      packages.jitsi-matrix-relay =
        pkgs.writers.writePython3Bin "jitsi-matrix-relay"
          {
            libraries = with pkgs.python3Packages; [
              aiohttp
              slixmpp
            ];
            flakeIgnore = [ "E501" ];
          }
          (
            builtins.replaceStrings [ "@widget@" ] [ "${./widget.html}" ] (
              builtins.readFile ./jitsi_matrix_relay.py
            )
          );
    };
}
