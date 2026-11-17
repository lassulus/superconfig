{
  self,
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
in
{
  imports = [ self.inputs.hermes-agent.nixosModules.default ];

  # Matrix DM cron briefs are seeded under the group session key, so the
  # in-thread reply never sees the brief (hermes-agent#141429); drop once
  # upstream fixes #141429.
  # On Anthropic OAuth the tool catalog names session_search by its wire
  # alias chat_history_lookup, which tool_describe/tool_call did not map
  # back (local fix, not upstream).
  services.hermes-agent.package =
    self.inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override
      (old: {
        uv2nix = patchHermesWheel old.uv2nix;
      });
}
