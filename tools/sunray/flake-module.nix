{
  perSystem =
    { pkgs, ... }:
    {
      packages.sunray =
        (pkgs.writeShellApplication {
          name = "sunray";
          runtimeInputs = [
            pkgs.openssh
            pkgs.moonlight-qt
            pkgs.gawk
          ];
          text = builtins.readFile ./sunray.sh;
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
