{ ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      # Gateway of the shared browser sessions (module.nix,
      # configs/services/browser-sessions).
      packages.browser-sessions = pkgs.buildGoModule {
        pname = "browser-sessions";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.fileFilter (f: f.hasExt "go" || f.name == "go.mod") ./.;
        };
        vendorHash = null;
        env.CGO_ENABLED = 0;
        meta = {
          mainProgram = "browser-sessions";
          platforms = lib.platforms.linux;
        };
      };
    };
}
