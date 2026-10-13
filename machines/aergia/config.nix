{ pkgs, ... }:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/browsers.nix
    ../../configs/network-manager.nix
    ../../configs/syncthing.nix
    ../../configs/pass.nix
    ../../configs/mail.nix
    # ../../configs/review.nix
    ../../configs/br.nix
  ];

  system.stateVersion = "22.11";

  environment.systemPackages = [
    pkgs.android-tools
  ];

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };
  services.pulseaudio.package = pkgs.pulseaudioFull;

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  services.tor = {
    enable = true;
    client.enable = true;
  };

  documentation.nixos.enable = true;
  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
  ];

  boot.tmp.cleanOnBoot = true;
  programs.noisetorch.enable = true;
}
