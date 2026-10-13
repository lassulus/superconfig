{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.gg23-audio =
        (pkgs.writeShellApplication {
          name = "gg23-audio";
          runtimeInputs = [
            pkgs.pulseaudio
            pkgs.gawk
          ];
          text = builtins.readFile ./gg23-audio.sh;
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
