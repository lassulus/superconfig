# omp links the system oniguruma/zstd on nixos-unstable but does not declare them (NixOS/nixpkgs#584803)
{ lib, ... }:
{
  nixpkgs.overlays = [
    (_final: prev: {
      omp =
        # buildInputs holds the dev outputs, so compare by pname
        assert lib.assertMsg (
          !lib.any (d: (d.pname or "") == "zstd") prev.omp.buildInputs
        ) "nixpkgs omp links zstd now, remove configs/build-fixes/omp.nix";
        prev.omp.overrideAttrs (old: {
          buildInputs = old.buildInputs ++ [
            prev.oniguruma
            prev.zstd
          ];
        });
    })
  ];
}
