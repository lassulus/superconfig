{ lib, ... }:
{
  # import every other .nix file in this directory
  imports = map (name: ./. + "/${name}") (
    builtins.filter (name: name != "default.nix" && lib.hasSuffix ".nix" name) (
      builtins.attrNames (builtins.readDir ./.)
    )
  );
}
