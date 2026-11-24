{ self, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    {
      # Gateway and backend of the shared browser sessions (module.nix,
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

      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
        browser-sessions = import ./test.nix { inherit self pkgs; };
      };
    };
}
