{
  perSystem =
    { pkgs, ... }:
    {
      packages.yt-dlp = pkgs.callPackage ./package.nix { };
    };
}
