{ inputs, lib, ... }:
{
  perSystem =
    { system, ... }:
    {
      # nix build .#kiosk-stick-iso, then dd result/iso/kiosk-stick.iso to the stick
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        kiosk-stick-iso =
          (inputs.nixpkgs.lib.nixosSystem {
            modules = [
              ./configuration.nix
              { nixpkgs.hostPlatform = system; }
            ];
          }).config.system.build.isoImage;
      };
    };
}
