# Live USB stick for a machine without a usable disk: boots straight into a
# Firefox that fills the screen (cage), with a WiFi picker in front of it
# while there is no network. Nothing is persisted, everything lives in RAM.
{
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  kiosk-session = pkgs.writeShellApplication {
    name = "kiosk-session";
    runtimeInputs = [
      pkgs.networkmanager
      pkgs.zenity
      pkgs.coreutils
      pkgs.firefox
    ];
    text = builtins.readFile ./kiosk-session.sh;
  };
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/iso-image.nix" ];

  system.stateVersion = lib.trivial.release;

  image.baseName = lib.mkForce "kiosk-stick";
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;
  # level 19 (the default) takes minutes; 3 is a bit bigger, the stick has room
  isoImage.squashfsCompression = "zstd -Xcompression-level 3";
  hardware.enableAllHardware = true;
  hardware.enableRedistributableFirmware = true;

  networking.hostName = "kiosk";
  networking.networkmanager.enable = true;
  time.timeZone = "Europe/Berlin";
  fonts.enableDefaultPackages = true;

  users.users.kiosk = {
    isNormalUser = true;
    # fixed, the media key bindings below address its pipewire by /run/user/<uid>
    uid = 1000;
    # the networkmanager group may change connections without a polkit prompt
    extraGroups = [ "networkmanager" ];
  };

  # pipewire runs in the kiosk user's session (cage opens one), Firefox talks
  # to it through pipewire-pulse
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # cage has no key bindings and Firefox ignores the volume keys, so
  # triggerhappy reads them from /dev/input and runs wpctl as the kiosk user.
  # "hold" is the key repeat, holding a volume key keeps changing it.
  services.triggerhappy = {
    enable = true;
    user = "kiosk";
    bindings =
      let
        wpctl = "XDG_RUNTIME_DIR=/run/user/1000 ${lib.getExe' pkgs.wireplumber "wpctl"}";
        volume =
          key: change:
          map
            (event: {
              keys = [ key ];
              inherit event;
              cmd = "${wpctl} set-volume --limit 1.0 @DEFAULT_AUDIO_SINK@ ${change}";
            })
            [
              "press"
              "hold"
            ];
      in
      volume "VOLUMEUP" "5%+"
      ++ volume "VOLUMEDOWN" "5%-"
      ++ [
        {
          keys = [ "MUTE" ];
          cmd = "${wpctl} set-mute @DEFAULT_AUDIO_SINK@ toggle";
        }
        {
          keys = [ "MICMUTE" ];
          cmd = "${wpctl} set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
        }
      ];
  };

  services.cage = {
    enable = true;
    user = "kiosk";
    program = lib.getExe kiosk-session;
    # no window decorations, Firefox takes the whole screen
    extraArguments = [ "-d" ];
  };
  # the session loops forever; should cage still die, bring it back
  systemd.services.cage-tty1.serviceConfig.Restart = "always";

  programs.firefox = {
    enable = true;
    policies = {
      DisplayBookmarksToolbar = "never";
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DontCheckDefaultBrowser = true;
      NoDefaultBookmarks = true;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
      UserMessaging = {
        ExtensionRecommendations = false;
        FeatureRecommendations = false;
        SkipOnboarding = true;
        MoreFromMozilla = false;
      };
      # start on an empty page with the cursor in the address bar
      Homepage = {
        URL = "about:blank";
        StartPage = "homepage";
      };
      NewTabPage = false;
    };
  };
}
