# paperless-ngx 3.4.2 pins torch<2.15, nixos-unstable ships torch 2.15 (fixed on nixpkgs master: NixOS/nixpkgs@bcc1381459b7)
{ lib, ... }:
{
  nixpkgs.overlays = [
    (_final: prev: {
      paperless-ngx =
        assert lib.assertMsg (
          !lib.elem "torch" prev.paperless-ngx.pythonRelaxDeps
        ) "nixpkgs paperless-ngx relaxes torch now, remove configs/build-fixes/paperless.nix";
        prev.paperless-ngx.overrideAttrs (old: {
          pythonRelaxDeps = old.pythonRelaxDeps ++ [ "torch" ];
        });
    })
  ];
}
