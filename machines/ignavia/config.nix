{
  self,
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/tpm2.nix
    ../../configs/phonetpm-ssh.nix
    ../../configs/desktops/sway/default.nix
    self.wrapperModules.workspace-manager
    ../../configs/power-action.nix
    ../../configs/yubikey.nix
    ../../configs/pipewire.nix
    ../../configs/bluetooth.nix
    ../../configs/udisks.nix
    ../../configs/browsers.nix
    ../../configs/network-manager.nix
    ../../configs/syncthing.nix
    # ../../configs/games.nix
    ../../configs/steam.nix
    # ../../configs/wine.nix
    ../../configs/pass.nix
    ../../configs/mail.nix
    ../../configs/printing
    ../../configs/auto-timezone.nix
    ../../configs/review.nix
    ../../configs/yggdrasil.nix
    ../../configs/container-tests.nix
    ../../configs/rad.nix
    ../../configs/tablet-screen.nix
    # ../../configs/br.nix
  ];

  system.stateVersion = "23.11";

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  services.tor = {
    enable = true;
    client.enable = true;
  };

  lass.workspace-manager.enable = true;

  # Suspend on power button press instead of shutting down.
  services.logind.settings.Login.HandlePowerKey = "suspend";

  # Auto-GC during builds when store free space drops below 10 GB,
  # freeing down to 20 GB free. (gc.automatic is off for ignavia.)
  nix.settings.min-free = 10240 * 1024 * 1024;
  nix.settings.max-free = 20480 * 1024 * 1024;

  # Framework 13 panel (2880x1920). wlroots' HiDPI heuristic auto-picks
  # scale 2 on every sway start, which is far too large. Pin the internal
  # panel to 1.0.
  # The external AORUS FO32U2 (4K) comes up at 2560x1440@240 without an
  # explicit mode; pin native 4K@240. Matched by make/model/serial since
  # its connector name (DP-3, DP-11, DP-13, ...) changes between plugs.
  environment.etc."sway/config.d/outputs.conf".text = ''
    output eDP-1 scale 1
    output "GIGA-BYTE TECHNOLOGY CO., LTD. AORUS FO32U2 24350B005397" mode 3840x2160@240Hz
  '';

  documentation.nixos.enable = true;
  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
  ];

  boot.tmp.cleanOnBoot = true;
  programs.noisetorch.enable = true;

  environment.systemPackages = [
    pkgs.android-tools
    pkgs.gh
    self.packages.${pkgs.system}.bank
    pkgs.ddcutil
    pkgs.rbw
  ];

  # styx on the gg23 LAN; appended to the kartei-built host file
  services.tinc.networks.retiolum.hosts.styx = lib.mkAfter "Address = 10.42.0.3 655";

  virtualisation.podman.enable = true;

  hardware.keyboard.qmk.enable = true;
  hardware.xpadneo.enable = true;
  hardware.bluetooth.settings.General = {
    # Xbox Wireless Controllers fail LE authentication without these:
    # JustWorksRepairing lets bluez accept fresh pairings without manual remove,
    # Privacy = device makes the host use a static address so the controller's
    # bond key doesn't get invalidated by RPA rotation.
    JustWorksRepairing = "always";
    Privacy = "device";
  };
  users.users.mainUser.extraGroups = [
    "wireshark"
    "i2c"
  ];
  users.groups.i2c = { };
  programs.wireshark.enable = true;
  programs.wireshark.package = pkgs.wireshark-qt;

  services.udev.packages = [ pkgs.libmtp.out ];

  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK =
    "/run/user/${toString config.users.users.mainUser.uid}/ssh-tpm-agent.sock";
}
