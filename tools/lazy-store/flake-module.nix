{ ... }:
{
  perSystem =
    { lib, pkgs, ... }:
    {
      # FUSE file system that serves /nix/store paths from the binary caches
      # without downloading them up front, for CI's machine builds
      # (.github/lazy-store.sh).
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        lazy-store = pkgs.callPackage ./package.nix { };
      };
    };
}
