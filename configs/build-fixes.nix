# Packages that fail to build since nixos-unstable links Rust crates against
# the system's C libraries instead of their bundled copies, and that do not
# declare those libraries yet. Fixed in nixpkgs master, not yet in
# nixos-unstable; each fix throws once nixpkgs ships it.
{ lib, ... }:
let
  # buildInputs holds the dev outputs, so compare by pname
  links = pkg: name: lib.any (d: (d.pname or "") == name) pkg.buildInputs;
in
{
  nixpkgs.overlays = [
    (_final: prev: {
      # NixOS/nixpkgs#584537
      radicle-node =
        assert lib.assertMsg (
          !links prev.radicle-node "libgit2"
        ) "nixpkgs radicle-node links libgit2 now, drop it from configs/build-fixes.nix";
        prev.radicle-node.overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ prev.pkg-config ];
          buildInputs = (old.buildInputs or [ ]) ++ [ prev.libgit2 ];
        });
      radicle-httpd =
        assert lib.assertMsg (
          !links prev.radicle-httpd "libgit2"
        ) "nixpkgs radicle-httpd links libgit2 now, drop it from configs/build-fixes.nix";
        prev.radicle-httpd.overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ prev.pkg-config ];
          buildInputs = (old.buildInputs or [ ]) ++ [
            prev.libgit2
            prev.zstd
          ];
        });
      # NixOS/nixpkgs#584803
      omp =
        assert lib.assertMsg (
          !links prev.omp "zstd"
        ) "nixpkgs omp links zstd now, drop it from configs/build-fixes.nix";
        prev.omp.overrideAttrs (old: {
          buildInputs = old.buildInputs ++ [
            prev.oniguruma
            prev.zstd
          ];
        });
    })
  ];
}
