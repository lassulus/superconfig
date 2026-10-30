{ ... }:
{
  flake.wrapperModules.noctalia =
    {
      config,
      lib,
      ...
    }:
    let
      pkgs = config.pkgs;
      tomlFormat = pkgs.formats.toml { };
    in
    {
      _class = "wrapper";

      options.settings = lib.mkOption {
        type = tomlFormat.type;
        default = { };
        example = lib.literalExpression ''
          {
            hooks.theme_mode_changed = "switch-theme $NOCTALIA_THEME_MODE";
          }
        '';
        description = ''
          Noctalia config, written to a read-only `noctalia/config.toml`
          that `NOCTALIA_CONFIG_HOME` points at. Changes made in the
          settings GUI go to `~/.local/state/noctalia/settings.toml` and
          win over these values.
        '';
      };

      # Clicking a workspace in the bar brings it to that bar's output on
      # sway, instead of jumping to the output it is on.
      config.package = lib.mkDefault (
        pkgs.noctalia.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./sway-workspace-to-output.patch ];
        })
      );

      config.env.NOCTALIA_CONFIG_HOME = "${pkgs.linkFarm "noctalia-config" {
        "noctalia/config.toml" = tomlFormat.generate "config.toml" config.settings;
      }}";

      config.meta.maintainers = [
        {
          name = "lassulus";
          github = "lassulus";
          githubId = 621375;
        }
      ];
      config.meta.platforms = lib.platforms.linux;
    };
}
