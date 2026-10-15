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

          allPackages = lib.packagesFromDirectoryRecursive {
            inherit callPackage;
            directory = ./.;
          };
        in
        # Packages for other platforms are left out via meta.platforms, so a
        # package's meta must evaluate on every system, also on the ones it
        # does not support; a package that throws breaks the evaluation.
        lib.filterAttrs (
          name: pkg: name != "flake-module" && lib.meta.availableOn pkgs.stdenv.hostPlatform pkg
        ) allPackages;

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
