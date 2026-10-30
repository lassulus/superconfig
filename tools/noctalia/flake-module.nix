{ self, inputs, ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      ...
    }:
    let
      noctalia = inputs.wrappers.lib.wrapModule {
        imports = [ self.wrapperModules.noctalia ];
        inherit pkgs;

        # ddcutil is run as a program for DDC/CI brightness.
        extraPackages = [ pkgs.ddcutil ];

        settings = {
          # Mirror noctalia's dark mode toggle to the system theme.
          hooks.theme_mode_changed = ''switch-theme "$NOCTALIA_THEME_MODE"'';
          # DDC/CI control for external monitors via ddcutil. Inert on
          # machines without DDC/CI-capable displays.
          brightness.enable_ddcutil = true;
          # Show all workspaces on every bar, by full name.
          widget.workspaces = {
            label_source = "name";
            max_label_chars = 20;
            show_all_outputs = true;
          };
        };
      };
    in
    {
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        noctalia = noctalia.wrapper;
      };
    };
}
