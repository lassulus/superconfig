{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.zitadel-invite =
        (pkgs.writers.writePython3Bin "zitadel-invite" { } ./zitadel_invite.py).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
