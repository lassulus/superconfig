{ ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      inputs',
      ...
    }:
    {
      packages =
        let
          # pkgs.callPackage plus llm-agents, for packages that patch one of
          # its agents (pkgs.orca is the GNOME screen reader, not this one).
          callPackage = pkgs.newScope { llm-agents = inputs'.llm-agents.packages; };

          # Wrapper that handles platform-incompatible packages by:
          # 1. Catching eval errors during callPackage
          # 2. Filtering based on meta.platforms
          platformAwareCallPackage =
            path: args:
            let
              result = builtins.tryEval (callPackage path args);
              pkg = result.value;
              isSupported = result.success && lib.meta.availableOn pkgs.stdenv.hostPlatform pkg;
            in
            if isSupported then pkg else null;

          allPackages = lib.packagesFromDirectoryRecursive {
            callPackage = platformAwareCallPackage;
            directory = ./.;
          };
        in
        lib.filterAttrs (name: pkg: name != "flake-module" && pkg != null) allPackages;

      # Fails the build (not the evaluation) once llm-agents moves past the
      # releases stablyai deleted, so the pin in pkgs/orca gets dropped. An
      # assert in pkgs/orca would be swallowed by the tryEval above.
      checks.orca-pin =
        let
          inherit (inputs'.llm-agents.packages.orca) version;
        in
        pkgs.runCommand "orca-pin" { } (
          if version == "1.4.226" then
            "touch $out"
          else
            ''
              echo "llm-agents now ships orca ${version}; remove the 1.4.224 pin in pkgs/orca and this check" >&2
              exit 1
            ''
        );
    };
}
