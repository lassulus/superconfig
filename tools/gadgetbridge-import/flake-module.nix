{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # Garmin samples from a Gadgetbridge database export into
      # VictoriaMetrics (configs/health-dav.nix).
      packages.gadgetbridge-import =
        (pkgs.writeShellApplication {
          name = "gadgetbridge-import";
          text = ''
            exec ${pkgs.python3}/bin/python3 ${./gadgetbridge_import.py} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
