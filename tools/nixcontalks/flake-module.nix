{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # License consent links for NixCon speakers (nixcontalks.lassul.us,
      # configs/nixcontalks.nix).
      packages.nixcontalks =
        (pkgs.writeShellApplication {
          name = "nixcontalks";
          text = ''
            exec ${pkgs.python3}/bin/python3 ${./nixcontalks.py} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
