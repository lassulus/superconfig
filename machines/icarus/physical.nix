{
  modulesPath,
  lib,
  ...
}:
{
  imports = [
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.loader.grub.device = "/dev/disk/by-id/wwn-0x5002538d702f5ac6";
  boot.initrd.luks.devices.ssd.device = "/dev/disk/by-id/wwn-0x5002538d702f5ac6-part3";

  boot.initrd.availableKernelModules = [
    "ehci_pci"
    "ahci"
    "xhci_pci"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.initrd.kernelModules = [ "dm-snapshot" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/298eb635-8db2-4c15-a73d-2e0d6afa10e8";
    fsType = "xfs";
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/eec94bef-e745-4d95-ad17-4df728f5fd31";
    fsType = "xfs";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/D975-2CAB";
    fsType = "vfat";
  };

  swapDevices = [ ];

  nix.maxJobs = lib.mkDefault 4;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

  services.udev.extraRules = ''
    SUBSYSTEM=="net", ATTR{address}=="00:24:d7:f0:a0:0c", NAME="wl0"
    SUBSYSTEM=="net", ATTR{address}=="f0:de:f1:71:cb:35", NAME="et0"
  '';

  services.logind.lidSwitch = "ignore";

  # 1 GiB /boot, one generation's kernel+initrd is ~80 MiB
  boot.loader.grub.configurationLimit = 10;
}
