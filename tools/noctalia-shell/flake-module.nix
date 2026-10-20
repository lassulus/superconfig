{ self, inputs, ... }:
{
  perSystem =
    { pkgs, self', ... }:
    let
      noctalia = inputs.wrappers.lib.wrapModule {
        imports = [ self.wrapperModules.noctalia-shell ];
        inherit pkgs;
        inherit (self'.packages) noctalia-qs;

        # Declarative settings merged into ~/.config/noctalia/settings.json
        # on every start. Anything not listed here remains user-mutable.
        settings = {
          hooks = {
            enabled = true;
            # Mirror noctalia's dark mode toggle to the system theme.
            darkModeChange = ''if [ "$1" = "true" ]; then switch-theme dark; else switch-theme light; fi'';
          };
          # noctalia owns the desktop background. It draws a static image (or
          # a solid colour), unlike the mpvpaper live video wallpaper it
          # replaced: a looping video on every output means every frame is
          # full-screen motion, which is unusable for the sunshine-streamed
          # tablet screen (configs/tablet-screen.nix) and pointless power
          # draw on the real ones. Pick the image in noctalia's wallpaper
          # panel; only `enabled` is pinned here.
          wallpaper.enabled = true;
          # DDC/CI control for external monitors via ddcutil. Inert on
          # machines without DDC/CI-capable displays (detection finds
          # nothing, internal backlight path is used as before).
          brightness.enableDdcSupport = true;
          # Don't pop the changelog panel on every startup; it is an
          # interruption nobody asked for. Note this is *only* the changelog
          # (UpdateService.showLatestChangelog): the separate telemetry wizard
          # is gated on noctalia's cache, not on this setting. Telemetry itself
          # is already off by default (general.telemetryEnabled = false).
          general.showChangelogOnStartup = false;
        };

        settingsPatches = [
          # Show workspace names (not indices) in the bar, and don't
          # truncate them. The widget caps to 2 chars on vertical bars
          # regardless; this only affects horizontal bars.
          ''.bar.widgets.center |= map(if .id == "Workspace" then .labelMode = "name" | .characterCount = 20 else . end)''
        ];
      };
    in
    {
      packages.noctalia-shell = noctalia.wrapper;
    };
}
