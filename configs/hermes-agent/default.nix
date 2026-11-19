{
  self,
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  # The package's override arguments do not reach its uv2nix python set, only
  # the uv2nix it is built with: wrap loadWorkspace so the workspace overlay
  # patches the hermes-agent wheel source. A patch that stops applying fails
  # the build.
  patchHermesWheel =
    uv2nix:
    lib.recursiveUpdate uv2nix {
      lib.workspace.loadWorkspace =
        args:
        let
          workspace = uv2nix.lib.workspace.loadWorkspace args;
        in
        workspace
        // {
          mkPyprojectOverlay =
            overlayArgs:
            lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) (
              _final: prev:
              # pm-runtime.nix loads a second workspace without hermes-agent.
              lib.optionalAttrs (prev ? hermes-agent) {
                hermes-agent = prev.hermes-agent.overrideAttrs (old: {
                  patches = (old.patches or [ ]) ++ [
                    ./hermes-cron-matrix-dm-seed.patch
                    ./hermes-oauth-alias-bridge-args.patch
                  ];
                });
              }
            );
        };
    };

  # Matrix DM cron briefs are seeded under the group session key, so the
  # in-thread reply never sees the brief (hermes-agent#141429); drop once
  # upstream fixes #141429.
  # On Anthropic OAuth the tool catalog names session_search by its wire
  # alias chat_history_lookup, which tool_describe/tool_call did not map
  # back (local fix, not upstream).
  package =
    self.inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override
      (old: {
        uv2nix = patchHermesWheel old.uv2nix;
      });

  # The gateway exits 1 on any SIGTERM it was not told about beforehand, so
  # every systemctl stop/restart (each deploy) ended as "Failed with result
  # 'exit-code'" and fired SystemdUnitFailed. `hermes gateway stop` announces
  # itself with a planned-stop marker first; systemd runs ExecStop before it
  # sends SIGTERM, so write the same marker for $MAINPID here. Real crashes
  # still exit 1. Drop once upstream ships it (NousResearch/hermes-agent
  # issue 42517, PR 24351) and the NixOS module uses it.
  plannedStop =
    package:
    "${pkgs.writeShellScript "hermes-planned-stop" ''
      [ -n "''${MAINPID:-}" ] || exit 0
      exec ${package.passthru.hermesVenv}/bin/python3 -c \
        'import os; from gateway.status import write_planned_stop_marker; write_planned_stop_marker(int(os.environ["MAINPID"]))'
    ''}";

  upstreamModule =
    let
      # flake-parts wraps the module function in nested { imports = [ … ]; }.
      unwrap =
        m:
        if lib.isFunction m then
          m
        else
          assert lib.length m.imports == 1;
          unwrap (lib.head m.imports);
    in
    unwrap self.inputs.hermes-agent.nixosModules.default;

  # services.hermes-agent is a singleton (unit hermes-agent, activation script
  # hermes-agent-setup, everything read off config.services.hermes-agent). An
  # instance calls the upstream module function with its own config and
  # options in place of services.hermes-agent, so it has every upstream option
  # and default, and `output` holds the NixOS config upstream produces for it
  # (properties resolved). The config below copies that out, with the unit
  # and the activation script renamed.
  instanceModule =
    {
      name,
      config,
      options,
      ...
    }:
    let
      upstream = upstreamModule {
        inherit lib pkgs;
        config = nixos.config // {
          services = nixos.config.services // {
            hermes-agent = config;
          };
        };
        options = nixos.options // {
          services = nixos.options.services // {
            hermes-agent = options;
          };
        };
      };
    in
    {
      options = upstream.options.services.hermes-agent // {
        output = lib.mkOption {
          type = lib.types.lazyAttrsOf lib.types.anything;
          internal = true;
          readOnly = true;
        };
      };
      config = {
        enable = lib.mkDefault true;
        package = lib.mkDefault package;
        user = lib.mkDefault "hermes-${name}";
        group = lib.mkDefault "hermes-${name}";
        stateDir = lib.mkDefault "/var/lib/hermes-${name}";
        # upstream merges mcpServers into services.hermes-agent.settings
        settings = lib.mkIf (config.output ? services) config.output.services.hermes-agent.settings;
        output = upstream.config;
      };
    };

  nixos = { inherit config options; };
  forInstances = f: lib.mkMerge (lib.mapAttrsToList f config.lass.hermes.instances);

  # The parts of an instance's output copied below; `true` copies the subtree.
  copied = {
    assertions = true;
    environment = true;
    services.hermes-agent.settings = true;
    system.activationScripts.hermes-agent-setup = true;
    systemd = {
      services.hermes-agent = true;
      services.hermes-backend = true;
      tmpfiles = true;
    };
    users = true;
    virtualisation = true;
    warnings = true;
  };
  notCopied =
    copied: output:
    lib.concatLists (
      lib.mapAttrsToList (
        n: v:
        if !copied ? ${n} then
          [ n ]
        else if copied.${n} == true then
          [ ]
        else
          map (p: "${n}.${p}") (notCopied copied.${n} v)
      ) output
    );
in
{
  imports = [ upstreamModule ];

  options.lass.hermes.instances = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule instanceModule);
    default = { };
    description = ''
      Hermes gateways, any number per host, each with the options of
      services.hermes-agent. Defaults: user and group hermes-<name>,
      stateDir /var/lib/hermes-<name>; the unit is hermes-<name>.service.
    '';
  };

  config = lib.mkMerge [
    {
      services.hermes-agent.package = package;
      systemd.services.hermes-agent = lib.mkIf config.services.hermes-agent.enable {
        serviceConfig.ExecStop = plannedStop config.services.hermes-agent.package;
      };
    }
    {
      users = forInstances (_: i: i.output.users or { });
      environment = forInstances (_: i: i.output.environment or { });
      virtualisation = forInstances (_: i: i.output.virtualisation or { });
      warnings = forInstances (_: i: i.output.warnings or [ ]);
      assertions = forInstances (
        name: i:
        i.output.assertions or [ ]
        ++ [
          {
            # its container is always named hermes-agent
            assertion = !i.container.enable;
            message = "lass.hermes.instances.${name}: container mode is not supported";
          }
          {
            assertion = notCopied copied i.output == [ ];
            message = "lass.hermes.instances.${name}: configs/hermes-agent does not copy ${toString (notCopied copied i.output)} from the upstream module";
          }
        ]
      );
      systemd.tmpfiles = forInstances (_: i: i.output.systemd.tmpfiles or { });
      # Names fixed here, not mapped from the output: upstream reads
      # system.activationScripts and users.users back, so neither their key
      # sets nor the merge that computes them may evaluate the output.
      systemd.services = forInstances (
        name: i: {
          "hermes-${name}" = lib.mkIf i.enable (
            lib.mkMerge [
              i.output.systemd.services.hermes-agent
              { serviceConfig.ExecStop = plannedStop i.package; }
            ]
          );
          "hermes-${name}-backend" = lib.mkIf (
            i.enable && i.backend.mode != "none"
          ) i.output.systemd.services.hermes-backend;
        }
      );
      system.activationScripts = forInstances (
        name: i: {
          "hermes-${name}-setup" = lib.mkIf i.enable {
            inherit (i.output.system.activationScripts.hermes-agent-setup) deps text;
          };
        }
      );
    }
  ];
}
