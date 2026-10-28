{
  lib,
  config,
  pkgs,
  ...
}:
let
  kmods = import ./signed-kmods.nix {
    inherit lib;
    inherit (config.boot) kernelPackages;
  };
in
{
  # Hardware configuration from krebs/stockholm x220.nix, with updated package names
  networking.wireless.enable = lib.mkDefault true;

  hardware.enableRedistributableFirmware = true;

  hardware.cpu.intel.updateMicrocode = true;

  hardware.graphics.enable = true;

  hardware.graphics.extraPackages = [
    pkgs.intel-vaapi-driver
    pkgs.libva-vdpau-driver
  ];

  services.xserver.videoDriver = "intel";

  boot = {
    initrd.luks.devices.luksroot.device = "/dev/sda3";
    initrd.availableKernelModules = [
      "xhci_hcd"
      "ehci_pci"
      "ahci"
      "usb_storage"
    ];
    extraModulePackages = [
      kmods.tp_smapi
      kmods.acpi_call
    ];
    kernelModules = [
      "kvm-intel"
      "acpi_call"
      "tp_smapi"
      "tpm-rng"
    ];
    kernelParams = [ "acpi_backlight=none" ];
  };

  fileSystems = {
    "/" = {
      device = "/dev/mapper/pool-root";
      fsType = "btrfs";
      options = [
        "defaults"
        "noatime"
        "ssd"
        "compress=lzo"
      ];
    };
    "/boot" = {
      device = "/dev/sda2";
      fsType = "vfat";
    };
    "/home" = {
      device = "/dev/mapper/pool-home";
      fsType = "btrfs";
      options = [
        "defaults"
        "noatime"
        "ssd"
        "compress=lzo"
      ];
    };
  };

  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchDocked = "ignore";

  services.tlp.enable = true;
  #services.tlp.extraConfig = ''
  #  START_CHARGE_THRESH_BAT0=80
  #  STOP_CHARGE_THRESH_BAT0=95
  #'';

  services.xserver.dpi = 80;
}
