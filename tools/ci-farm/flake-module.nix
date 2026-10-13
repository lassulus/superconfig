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
      # plain Linux runner. The farm identity on both sides: the clients in
      # the machine jobs reach it over iroh, the nodes verify it and grant it
      # `trusted` (so it can read the builder list from the scheduler).
      envoySettings =
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
                tls = {
                  certFile = "/tmp/ci-farm/farm.crt";
                  keyFile = "/tmp/ci-farm/farm.key";
                  clientCaFile = "/tmp/ci-farm/farm.crt";
                  upstream = {
                    certFile = "/tmp/ci-farm/farm.crt";
                    keyFile = "/tmp/ci-farm/farm.key";
                    caFile = "/tmp/ci-farm/farm.crt";
                  };
                };
              };
            }
          ];
        }).config.services.envoy.settings;

      # The module verifies a client certificate but doesn't require one, and
      # passes requests on with the farm identity. Require it: the listener
      # is reachable over iroh.
      envoyConfig = (pkgs.formats.json { }).generate "ci-farm-envoy.json" (
        envoySettings
        // {
          static_resources = envoySettings.static_resources // {
            listeners = map (
              listener:
              listener
              // {
                filter_chains = map (
                  chain:
                  lib.recursiveUpdate chain { transport_socket.typed_config.require_client_certificate = true; }
                ) listener.filter_chains;
              }
            ) envoySettings.static_resources.listeners;
          };
        }
      );
    in
    {
      # ci-farm farm MACHINE...       scheduler + balancer until the machine
      #                               jobs of MACHINE... have finished
      # ci-farm machine INDEX NAME    builder, builds the toplevel of NAME
      #                               through the farm
      # ci-farm push PATH...          pushes the closures of PATH... to niks3
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
