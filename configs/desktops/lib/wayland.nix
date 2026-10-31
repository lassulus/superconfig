{
  self,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ../../alacritty.nix
    ../../kitty.nix
    ../../xdg-open.nix
    ../../yubikey.nix
    ../../themes.nix
    ../../fonts.nix
    # ../pipewire.nix
    # ./tty-share.nix
    {
      users.users.mainUser.packages = [
        pkgs.sshuttle
        self.packages.${pkgs.system}.mpv
      ];
      security.sudo.extraConfig = ''
        lass ALL= (root) NOPASSWD:SETENV: ${pkgs.sshuttle}/bin/.sshuttle-wrapped
      '';
    }
  ];

  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
  };

  users.users.mainUser.extraGroups = [
    "audio"
    "video"
    "input"
  ];

  xdg.portal.enable = true;
  xdg.portal.extraPortals = [
    pkgs.xdg-desktop-portal-gtk
    pkgs.xdg-desktop-portal-wlr
  ];
  xdg.portal.config.common.default = "wlr";
  # Firefox (and chromium, obs) always ask the ScreenCast portal for
  # MONITOR|WINDOW. xdg-desktop-portal-wlr then skips the slurp entry of its
  # default chooser list — slurp cannot pick a window — and falls through to the
  # dmenu-style entries (wmenu, wofi, rofi, bemenu, ...), none of which nixpkgs
  # wraps into the portal: NixOS/nixpkgs#471244. So SelectSources died with
  # "no output found" before any picker appeared and every screenshare failed.
  # Pin an absolute dmenu chooser, which lists monitors and windows alike.
  xdg.portal.wlr.settings.screencast = {
    chooser_type = "dmenu";
    chooser_cmd = "${lib.getExe pkgs.wofi} -d -n --prompt='Select a source to share:'";
  };
  fonts.enableDefaultPackages = true;

  # PipeWire runs system-wide and is usually not ready yet when sway starts the
  # screencast portal at login. The default unit retries every 100ms and trips
  # the start-limit within a second, then stays dead for the whole session —
  # which silently breaks screensharing. Keep retrying with a sane delay and no
  # give-up so it comes up as soon as PipeWire accepts connections.
  systemd.user.services.xdg-desktop-portal-wlr = {
    startLimitIntervalSec = 0;
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce 2;
    };
  };

  security.polkit.enable = true;

  programs.dconf.enable = lib.mkDefault true;
  services.gnome.gnome-keyring.enable = lib.mkDefault true;
  programs.xwayland.enable = lib.mkDefault true;

  environment.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    XDG_SESSION_TYPE = "wayland";
    SDL_VIDEODRIVER = "wayland";
    QT_QPA_PLATFORM = "wayland";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
    _JAVA_AWT_WM_NONREPARENTING = "1";
    NIXOS_OZONE_WL = "1"; # Hint for electron apps to use wayland
  };

  programs.wshowkeys.enable = true;

  environment.systemPackages = with pkgs; [
    pavucontrol
    swayidle
    rofi
    rofi-rbw
    eog
    libnotify
    mako # notifications
    kanshi # auto-configure display outputs
    wdisplays # buggy with qtile?
    wlr-randr
    wl-clipboard
    wev
    blueman
    grim # screenshots
    wtype
    zathura
    nsxiv

    pavucontrol
    evince
    libnotify
    pamixer
    file-roller
    xdg-utils
    # polkit agent
    polkit_gnome

    self.packages.${pkgs.system}.menu

    # gtk3 themes
    gsettings-desktop-schemas
    (pkgs.writers.writeDashBin "screenshot" ''
      ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.wl-clipboard}/bin/wl-copy
    '')
    (pkgs.writers.writeDashBin "type_paste" ''
      ${pkgs.wl-clipboard}/bin/wl-paste | ${pkgs.wtype}/bin/wtype -d 10 -s 400 -
    '')
  ];

  environment.pathsToLink = [
    "/libexec" # for polkit
    "/share/gsettings-schemas" # for XDG_DATA_DIRS
  ];

  qt.platformTheme = "qt5ct";
}
