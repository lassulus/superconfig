{
  description = "lassulus superconfig";

  inputs = {
    # tracking nixos-unstable; if a bump lands an uncached firefox-devedition (beta channel
    # isn't channel-gating on Hydra) it builds from source. Check first: s firefox-devedition-watch
    # then pin a cached rev here if needed: github:nixos/nixpkgs/<rev>
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # nixpkgs.url = "github:lassulus/nixpkgs/nixos-unstable";
    # nixpkgs.url = "path:/home/lass/tmp/nixpkgs-disk-debug";
    # nixpkgs.url = "git+file:/home/lass/src/nixpkgs";
    # nixpkgs.url = "git+file:/Users/lassulus/src/nixpkgs";

    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    # git.clan.lol is unreachable; use the GitHub mirrors.
    clan-core.url = "github:clan-lol/clan-core";
    # clan-core.url = "path:/Users/lassulus/src/clan/clan-core";
    # clan-core.url = "path:/home/lass/src/clan/clan-core";
    clan-core.inputs.nixpkgs.follows = "nixpkgs";
    clan-core.inputs.disko.follows = "disko";
    clan-core.inputs.nix-select.url = "github:clan-lol/nix-select";
    # data-mesher has no GitHub mirror. "" makes clan-core use this flake as
    # data-mesher; see the empty flake.nixosModules.data-mesher below.
    clan-core.inputs.data-mesher.follows = "";

    stockholm.url = "git+https://github.com/krebs/stockholm?submodules=1";
    # stockholm.url = "git+https://cgit.lassul.us/stockholm";
    # stockholm.url = "path:/home/lass/sync/stockholm";
    stockholm.inputs.nixpkgs.follows = "nixpkgs";
    stockholm.inputs.buildbot-nix.follows = "";

    # Host database only (modules/retiolum/hosts.nix), on every platform.
    # The daemon is pkgs/tincr everywhere; barnacle imports tincr's own
    # darwin module below, not kartei's retiolum shim.
    kartei.url = "github:krebs/kartei";
    kartei.inputs.nixpkgs.follows = "nixpkgs";
    kartei.inputs.tincr.follows = "tincr";
    kartei.inputs.crane.follows = "tincr/crane";
    kartei.inputs.fenix.follows = "tincr/fenix";

    # Only for darwinModules.tincr (launchd plumbing); the package comes
    # from pkgs/tincr, which pins the same fork branch.
    tincr.url = "github:Lassulus/tincr/lassulus/fixes";
    tincr.inputs.nixpkgs.follows = "nixpkgs";
    tincr.inputs.treefmt-nix.follows = "treefmt-nix";

    disko.url = "github:nix-community/disko";
    # disko.url = "path:/home/lass/src/disko/";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixos-hardware.url = "github:nixos/nixos-hardware";

    nether.url = "github:krebs/nether";
    # nether.url = "git+file:/home/lass/src/nether";
    nether.inputs.nixpkgs.follows = "nixpkgs";
    nether.inputs.clan-core.follows = "clan-core";
    nether.inputs.data-mesher.follows = "";

    spora.url = "github:krebs/spora";
    # spora.url = "git+file:/home/lass/src/spora";
    spora.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    nix-rosetta-builder.url = "github:cpick/nix-rosetta-builder";
    nix-rosetta-builder.inputs.nixpkgs.follows = "nixpkgs";

    nixos-facter.url = "github:numtide/nixos-facter-modules";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    le_menu.url = "github:lassulus/le_menu";
    # le_menu.url = "git+file:/home/lass/src/le_menu";
    le_menu.inputs.nixpkgs.follows = "nixpkgs";

    extra-container.url = "github:erikarvstedt/extra-container";
    extra-container.inputs.nixpkgs.follows = "nixpkgs";

    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";

    hermes-agent.url = "github:nousresearch/hermes-agent";
    hermes-agent.inputs.nixpkgs.follows = "nixpkgs";

    nixpkgs-triage.url = "github:Lassulus/nixpkgs-triage";
    nixpkgs-triage.inputs.nixpkgs.follows = "nixpkgs";

    rogue-talk.url = "github:rogue-talk/rogue-talk";
    rogue-talk.inputs.nixpkgs.follows = "nixpkgs";

    wrappers.url = "github:lassulus/wrappers";
    # wrappers.url = "git+file:/home/lass/src/wrappers";
    wrappers.inputs.nixpkgs.follows = "nixpkgs";

    opencrow.url = "github:pinpox/opencrow";
    opencrow.inputs.nixpkgs.follows = "nixpkgs";

    nixos-mailserver.url = "gitlab:simple-nixos-mailserver/nixos-mailserver";
    nixos-mailserver.inputs.nixpkgs.follows = "nixpkgs";

    covibe.url = "git+https://git.geninf.io/Lassulus/covibe";
    covibe.inputs.nixpkgs.follows = "nixpkgs";
    # One omp revision (and one build) for covibe's sessions and llm.omp.
    covibe.inputs.llm-agents.follows = "llm-agents";

    sigexec.url = "git+https://git.geninf.io/Lassulus/sigexec";
    sigexec.inputs.nixpkgs.follows = "nixpkgs";

    # build farm (configs/nix-farm): remote builds over grpc:// ...
    nix-grpc-store.url = "github:Mic92/nix-grpc-store";
    nix-grpc-store.inputs.nixpkgs.follows = "nixpkgs";
    nix-grpc-store.inputs.niks3.follows = "niks3";

    # ... and the S3-backed binary cache the outputs land in. Fork for
    # `push --ignore-upstream-key` (not upstream yet). It rebases onto
    # Mic92/niks3 daily (its .github/workflows/rebase-upstream.yml), so
    # `nix flake update niks3` follows upstream.
    niks3.url = "github:lassulus/niks3";
    niks3.inputs.nixpkgs.follows = "nixpkgs";
    niks3.inputs.treefmt-nix.follows = "treefmt-nix";

  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      clan-core,
      ...
    }:
    let
      clan = clan-core.lib.clan {
        self = self;
        specialArgs.self = self;
        modules = import ./clan_modules { inherit nixpkgs; };
        vars.settings.secretStore = "password-store";
        meta.domain = "s";
        inventory = {
          meta.name = "superconfig";
          machines = {
            ignavia.tags = [
              "laptop"
              "focus"
            ];
            mors.tags = [
              "laptop"
              "focus"
            ];
            aergia.tags = [
              "laptop"
              "focus"
            ];
            barnacle = {
              machineClass = "darwin";
              tags = [
                "laptop"
                "focus"
              ];
            };
            icarus.tags = [ "laptop" ];
            neoprism.tags = [ "server" ];
            starkstrom = {
              tags = [ "server" ];
              deploy.forwardAgent = true;
            };
            acheron.tags = [ "server" ];
          };
          instances = {
            tor = {
              roles.server.tags.all = { };
            };
            retiolum = {
              module.input = "self";
              roles.default.tags.nixos = { };
            };
            internet = {
              roles.default.machines = {
                neoprism.settings.host = "neoprism.lassul.us";
                neoprism.settings.port = 45621;
                starkstrom.settings.host = "194.110.87.67";
                starkstrom.settings.port = 45621;
              };
            };
            state-version = {
              module.name = "importer";
              roles.default.tags.all = { };
              roles.default.settings.extraModules = [
                {
                  clan.core.state-version.enable = true;
                }
              ];
            };
            yggdrasil = {
              roles.default.tags.nixos = { };
            };
            tor-yggdrasil = {
              module.name = "tor";
              roles.client.tags.nixos = { };
              roles.server.tags.nixos = { };
              roles.server.settings = {
                secretHostname = false;
                portMapping = [
                  {
                    # tcp
                    port = 6443;
                    target.port = 6443;
                  }
                  {
                    # tls
                    port = 6446;
                    target.port = 6443;
                  }
                ];
              };
            };
          };
        };
        machines =
          nixpkgs.lib.mapAttrs
            (machineName: _: {
              imports = [
                ./machines/${machineName}/physical.nix
              ];
            })
            (
              nixpkgs.lib.filterAttrs (
                machineName: _: builtins.pathExists ./machines/${machineName}/physical.nix
              ) (builtins.readDir ./machines)
            );
      };
    in
    clan-core.inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      imports = [
        ./formatter.nix
        ./pkgs/flake-module.nix
        ./keys/flake-module.nix
        ./retiolum/flake-module.nix
        ./skills/flake-module.nix

        ./wrapperModules/pi/flake-module.nix
        ./wrapperModules/claude-code/flake-module.nix
        ./wrapperModules/noctalia-shell/flake-module.nix
        {
          options.flake.wrapperModules = nixpkgs.lib.mkOption {
            type = nixpkgs.lib.types.lazyAttrsOf nixpkgs.lib.types.raw;
            default = { };
          };
        }
      ]
      ++ (
        # Auto-import all flake-module.nix files from tools subdirectories
        let
          toolDirs = builtins.attrNames (
            nixpkgs.lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./tools)
          );
        in
        map (dir: ./tools + "/${dir}/flake-module.nix") toolDirs
      );
      flake.nixosConfigurations = clan.config.nixosConfigurations;
      flake.clanInternals = clan.config.clanInternals;
      flake.darwinConfigurations = clan.config.darwinConfigurations;
      flake.clan = clan.config;
      # clan-core imports data-mesher's module unconditionally; we don't run
      # data-mesher or dm-dns, so an empty module stands in for it.
      flake.nixosModules.data-mesher = { };

      # Container configurations for use with extra-container
      # Auto-discovers machines with container.nix
      flake.containerConfigurations =
        nixpkgs.lib.mapAttrs
          (machineName: _: import ./machines/${machineName}/container.nix { inherit self; })
          (
            nixpkgs.lib.filterAttrs (
              machineName: _: builtins.pathExists ./machines/${machineName}/container.nix
            ) (builtins.readDir ./machines)
          );

      perSystem =
        {
          lib,
          pkgs,
          system,
          ...
        }:
        {
          packages = {
            default = inputs.le_menu.lib.buildMenu {
              inherit pkgs;
              menuConfig = {
                vim.run = "nix run ${self}#nvim";
                shell.run = "nix run ${self}#shell";
                machines.submenu = lib.mapAttrs (name: _machine: {
                  submenu.ssh.submenu = {
                    retiolum.run = "ssh -t ${name}.r";
                    spora.run = "ssh ${name}.s";
                    nether.run = "ssh ${name}.n";
                    tor.run = "torify ssh $(pass show machines/${name}/tor-hostname)";
                  };
                }) self.nixosConfigurations;
                debug.run = "env";
              };
            };
            clan-cli = clan-core.packages.${system}.clan-cli;
          }
          // lib.mapAttrs' (
            name: containerConfig:
            lib.nameValuePair "container-${name}" (
              inputs.extra-container.lib.buildContainers {
                inherit system;
                nixpkgs = inputs.nixpkgs;
                config = {
                  # Workaround: extra-container's minimal module set doesn't
                  # include nixos-init.nix, but systemd.nix now references
                  # config.system.nixos-init.package for env-generator.
                  # Provide a dummy option until extra-container is updated.

                  imports = [
                    (
                      { pkgs, lib, ... }:
                      {
                        options.system.nixos-init.package = lib.mkPackageOption pkgs "nixos-init" { };
                        options.time.timeZone = lib.mkOption {
                          type = lib.types.nullOr lib.types.str;
                          default = null;
                          description = "Dummy option for extra-container compatibility";
                        };
                        options.services.openssh = {
                          enable = lib.mkOption {
                            type = lib.types.bool;
                            default = false;
                            description = "Dummy option for extra-container compatibility";
                          };
                          package = lib.mkPackageOption pkgs "openssh" { };
                        };
                        # systemd.nix sets environment.variables.SYSTEMD_XKB_DIRECTORY,
                        # but the minimal module set omits config/system-environment.nix
                        # which declares the option.
                        options.environment.variables = lib.mkOption {
                          type = lib.types.attrsOf lib.types.anything;
                          default = { };
                          description = "Dummy option for extra-container compatibility";
                        };
                        # systemd.nix reads config.i18n.imperativeLocale, but the
                        # minimal module set omits config/i18n.nix which declares it.
                        options.i18n.imperativeLocale = lib.mkOption {
                          type = lib.types.bool;
                          default = true;
                          description = "Dummy option for extra-container compatibility";
                        };
                        # nixos-containers.nix reads config.nix.enable and
                        # config.nix.daemon.enable for the /nix/var/nix bind
                        # mounts, but the minimal module set omits
                        # config/nix.nix which declares them.
                        options.nix = {
                          enable = lib.mkOption {
                            type = lib.types.bool;
                            default = true;
                            description = "Dummy option for extra-container compatibility";
                          };
                          daemon.enable = lib.mkOption {
                            type = lib.types.bool;
                            default = true;
                            description = "Dummy option for extra-container compatibility";
                          };
                        };
                      }
                    )
                  ];
                  containers.${name} = containerConfig;
                };
              }
            )
          ) self.containerConfigurations;
          devShells.default = pkgs.mkShell {
            packages = [
              self.packages.${pkgs.system}.pass
              (self.legacyPackages.${system}.bin_shim {
                name = "clan";
                pkg_name = "clan-cli";
              })
            ];
          };
          # orca: see pkgs/orca (darwin launcher fix).
          legacyPackages.llm =
            inputs.llm-agents.packages.${system}
            // lib.optionalAttrs (self.packages.${system} ? orca) { inherit (self.packages.${system}) orca; };
          checks =
            let
              # Check NixOS configurations can be evaluated (without building)
              nixosChecks = lib.mapAttrs' (
                name: config:
                lib.nameValuePair "nixos-${name}" (
                  pkgs.runCommand "eval-${name}" { } ''
                    # Force evaluation of the toplevel path without building
                    echo "Evaluating ${name}: ${builtins.unsafeDiscardStringContext config.config.system.build.toplevel.drvPath}"
                    touch $out
                  ''
                )
              ) (lib.filterAttrs (_: config: config.pkgs.system == system) self.nixosConfigurations);

              # Check Darwin configurations can be evaluated (without building)
              darwinChecks = lib.mapAttrs' (
                name: config:
                lib.nameValuePair "darwin-${name}" (
                  pkgs.runCommand "eval-darwin-${name}" { } ''
                    # Force evaluation of the system path without building
                    echo "Evaluating ${name}: ${builtins.unsafeDiscardStringContext config.system.drvPath}"
                    touch $out
                  ''
                )
              ) (lib.filterAttrs (_: config: config.pkgs.system == system) self.darwinConfigurations);
            in
            nixosChecks // darwinChecks;
        };
      flake.lib = import ./lib { inherit (nixpkgs) lib; };
    };
}
