{ self, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      # needs psql in PATH; configs/services/git/pds.nix runs it
      packages.pds-reconcile = pkgs.writers.writePython3Bin "pds-reconcile" {
        libraries = [ pkgs.python3Packages.bcrypt ];
      } ./pds_reconcile.py;

      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        pds-reconcile = import ./test.nix { inherit self pkgs; };
      };
    };
}
