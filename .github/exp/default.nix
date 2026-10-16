# nix build -f .github/exp
{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:
pkgs.callPackage ./package.nix { }
