{
  config,
  lib,
  options,
  self,
  ...
}:
# Client of the neoprism build farm (configs/nix-farm), for NixOS and
# nix-darwin. The plugin finds client.crt/client.key in
# /var/lib/nix-grpc-store by itself; the CA has to be passed explicitly:
#   nix build --store 'grpc://neoprism.r:50051?ca-cert=/var/lib/nix-grpc-store/ca.crt' \
#     --eval-store auto .#nixosConfigurations.<m>.config.system.build.toplevel
let
  files = [
    "ca.crt"
    "client.crt"
    "client.key"
  ];
  client = config.clan.core.vars.generators.nix-farm-client.files;
in
{
  imports = [
    # darwinModules.default is only the daemon; the grpc:// plugin is in the
    # client module, which only sets nix.settings.plugin-files and works on
    # nix-darwin as is.
    "${self.inputs.nix-grpc-store}/nixos/client.nix"
    ./ca.nix
  ];

  config = lib.mkMerge [
    { programs.nix-grpc-store.enable = true; }

    # Per-machine copy of the shared CA's client files (see ca.nix).
    {
      clan.core.vars.generators.nix-farm-client = {
        dependencies = [ "nix-farm-ca" ];
        files = lib.genAttrs files (_: { });
        script = lib.concatMapStrings (f: ''
          cp "$in/nix-farm-ca/${f}" "$out/${f}"
        '') files;
      };
    }

    # Branch on options, not pkgs: the latter recurses through the attr names.
    (lib.optionalAttrs (options ? system.primaryUser) {
      # clan's /run/secrets installer is Linux-only, so these come in as
      # activation secrets (root-owned, below secretLocation) and are copied
      # to where the plugin looks by default, readable by the user running nix.
      clan.core.vars.generators.nix-farm-client.files = lib.genAttrs files (_: {
        deploy = true;
        neededFor = "activation";
      });
      # Skipped while the secrets have not been uploaded yet.
      system.activationScripts.postActivation.text = ''
        install -d -m 0755 /var/lib/nix-grpc-store
      ''
      + lib.concatMapStrings (f: ''
        if [ -e ${client.${f}.path} ]; then
          install -m 0400 -o ${config.system.primaryUser} ${client.${f}.path} /var/lib/nix-grpc-store/${f}
        fi
      '') files;
    })

    (lib.optionalAttrs (options ? systemd.tmpfiles) {
      # Regular /run/secrets, readable by wheel (the users running nix) and
      # root (nix-daemon's build hook), linked to where the plugin looks.
      clan.core.vars.generators.nix-farm-client.files = lib.genAttrs files (_: {
        deploy = true;
        group = "wheel";
        mode = "0440";
      });
      systemd.tmpfiles.rules = map (
        f: "L+ /var/lib/nix-grpc-store/${f} - - - - ${client.${f}.path}"
      ) files;
    })
  ];
}
