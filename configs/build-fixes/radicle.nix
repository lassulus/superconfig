# radicle links the system libgit2/zstd on nixos-unstable but does not declare them (NixOS/nixpkgs#584537)
{ lib, ... }:
let
  # buildInputs holds the dev outputs, so compare by pname
  links = pkg: name: lib.any (d: (d.pname or "") == name) pkg.buildInputs;
in
{
  nixpkgs.overlays = [
    (_final: prev: {
      radicle-node =
        assert lib.assertMsg (
          !links prev.radicle-node "libgit2"
        ) "nixpkgs radicle-node links libgit2 now, remove configs/build-fixes/radicle.nix";
        prev.radicle-node.overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ prev.pkg-config ];
          buildInputs = (old.buildInputs or [ ]) ++ [ prev.libgit2 ];
        });
      radicle-httpd =
        assert lib.assertMsg (
          !links prev.radicle-httpd "libgit2"
        ) "nixpkgs radicle-httpd links libgit2 now, remove configs/build-fixes/radicle.nix";
        prev.radicle-httpd.overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ prev.pkg-config ];
          buildInputs = (old.buildInputs or [ ]) ++ [
            prev.libgit2
            prev.zstd
          ];
        });
    })
  ];
}
