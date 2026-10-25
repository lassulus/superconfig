{
  pkgs,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/pipewire.nix
    ../../configs/browsers.nix
    ../../configs/network-manager.nix
    ../../configs/syncthing.nix
    ../../configs/games.nix
    ../../configs/steam.nix
    ../../configs/wine.nix
    ../../configs/review.nix
    ../../configs/rad.nix
    ../../configs/orca/ide.nix
    ../../configs/orca/server.nix
    ../../configs/crit.nix
    ../../configs/monitoring/server.nix
    ./strom.nix
    ./hermes.nix
    ./hermes-voice.nix
    ./backup.nix
  ];

  system.stateVersion = "24.05";

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];
  # 32 GB RAM: parallel rustc/ld builds (~10 GB each) OOM'd with max-jobs=16
  nix.settings.max-jobs = 4;

  services.tor = {
    enable = true;
    client.enable = true;
  };

  documentation.nixos.enable = true;

  environment.systemPackages = [
    pkgs.android-tools
    # atlas' et0, via the limited broadcast (wol's default): it follows the
    # default route, i.e. the wired NIC if connected (metric 100 < wifi 600).
    # Not the directed 10.79.135.255: that goes out of wlp3s0 and the AP
    # does not forward it to the wired LAN
    (pkgs.writeShellApplication {
      name = "wake-atlas";
      runtimeInputs = [ pkgs.wol ];
      text = "wol 70:85:c2:0e:ea:3c";
    })
  ];

  # adb/fastboot for the hermes service user, which uaccess (seat only)
  # skips. ID_DEBUG_APPLIANCE is set by systemd's 70-uaccess.rules.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_DEBUG_APPLIANCE}=="android", MODE="0660", GROUP="adbusers"
  '';
  users.groups.adbusers = { };
  users.users.hermes.extraGroups = [ "adbusers" ];
}
