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
    # the networkmanager group may change connections without a polkit prompt
    extraGroups = [ "networkmanager" ];
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
