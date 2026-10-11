{ inputs, ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      grpc = inputs.nix-grpc-store.packages.${system};

      # Envoy as configured by nix-grpc-store's NixOS module, rendered for a
      # plain Linux runner. Plaintext towards the local client, the farm
      # identity towards the nodes (they verify it and grant it `trusted`, so
      # it can read the builder list from the scheduler).
      envoyConfig =
        (pkgs.formats.json { }).generate "ci-farm-envoy.json"
          (inputs.nixpkgs.lib.nixosSystem {
            modules = [
              inputs.nix-grpc-store.nixosModules.lb
              {
                nixpkgs.pkgs = pkgs;
                services.nix-grpc-farm-lb = {
                  enable = true;
                  listen = "127.0.0.1:50051";
                  scheduler = "127.0.0.1:50052";
                  systems = [ system ];
                  # Written by ci-farm.sh. Envoy watches the directories of
                  # these files, so they must exist on the runner.
                  tls.upstream = {
                    certFile = "/tmp/ci-farm/farm.crt";
                    keyFile = "/tmp/ci-farm/farm.key";
                    caFile = "/tmp/ci-farm/farm.crt";
                  };
                };
              }
            ];
          }).config.services.envoy.settings;
    in
    {
      # ci-farm farm MACHINE...   scheduler + builder + balancer, builds the
      #                           toplevels of MACHINE... through the farm
      # ci-farm worker INDEX      builder, until the farm job has finished
      #
      # Runs in .github/workflows/farm.yml. See ci-farm.sh for the layout.
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        ci-farm = pkgs.writeShellApplication {
          name = "ci-farm";
          runtimeInputs = [
            grpc.default
            inputs.niks3.packages.${system}.niks3
            pkgs.coreutils
            pkgs.curl
            pkgs.dumbpipe
            pkgs.envoy-bin
            pkgs.gh
            pkgs.jq
          ];
          runtimeEnv = {
            FARM_CRT = ./farm.crt;
            ENVOY_CONFIG = envoyConfig;
            NIX_WITH_PLUGIN = lib.getExe grpc.nix-with-plugin;
          };
          text = builtins.readFile ./ci-farm.sh;
        };
      };
    };
}
