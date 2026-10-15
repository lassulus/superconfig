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
    };
}
