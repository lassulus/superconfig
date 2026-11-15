{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # Synced 24/7 channel (tv.lassul.us, configs/tv.nix).
      packages.tv = pkgs.buildGoModule {
        pname = "tv";
        version = "0.1.0";
        src = ./.;
        vendorHash = null;
        # TestPrepareKeyframes encodes with the ffmpeg configs/tv.nix uses
        nativeCheckInputs = [ pkgs.ffmpeg-headless ];
        meta.mainProgram = "tv";
        passthru.usage = builtins.readFile ./usage.kdl;
      };
    };
}
