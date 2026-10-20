{ config, lib, ... }:
let
  kmods = import ../../configs/hw/signed-kmods.nix {
    inherit lib;
    inherit (config.boot) kernelPackages;
  };
in
{
  imports = [
    ./config.nix
    ../../configs/boot/coreboot.nix
  ];

  fileSystems = {
    "/" = {
      device = "/dev/pool/root";
      fsType = "btrfs";
    };
    "/boot" = {
      device = "/dev/sda2";
      fsType = "ext4";
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
    # "/bku" = {
    #   device = "/dev/mapper/pool-bku";
    #   fsType = "btrfs";
    #   options = [
    #     "defaults"
    #     "noatime"
    #     "ssd"
    #     "compress=lzo"
    #   ];
    # };
    # "/backups" = {
    #   device = "/dev/pool/backup";
    #   fsType = "ext4";
    # };
  };

  boot = {
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
      "acpi_call"
      "tp_smapi"
    ];
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="net", ATTR{address}=="08:11:96:0a:5d:6c", NAME="wl0"
    SUBSYSTEM=="net", ATTR{address}=="f0:de:f1:71:cb:35", NAME="et0"
  '';

  boot.initrd.luks.devices.luksroot.device = "/dev/sda3";

  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchDocked = "ignore";

  services.tlp.enable = true;

  services.xserver.dpi = 80;
}
