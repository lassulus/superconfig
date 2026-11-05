{
  perSystem =
    { pkgs, ... }:
    {
      packages.sunray =
        (pkgs.writeShellApplication {
          name = "sunray";
          runtimeInputs = [
            pkgs.python3
            pkgs.openssh
            pkgs.moonlight-qt
          ];
          text = ''
            exec python3 ${./.}/sunray.py "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
