{ modulesPath, lib, ... }:

{
  imports = [
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "usbhid"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ "dm-snapshot" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
  boot.kernelParams = [
    "boot.shell_on_fail"
  ];

  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.device = "/dev/disk/by-id/ata-SanDisk_SSD_G5_BICS4_20248F446514";
  boot.loader.grub.efiInstallAsRemovable = true;

  fileSystems."/" = {
    device = "/dev/pool/root";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/EAA5-88A9";
    fsType = "vfat";
  };

  swapDevices = [ ];

  nix.maxJobs = lib.mkDefault 4;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

  services.udev.extraRules = ''
    SUBSYSTEM=="net", ATTR{address}=="3c:7c:3f:7e:e2:39", NAME="et0"
    SUBSYSTEM=="net", ATTR{address}=="00:e0:4c:78:91:50", NAME="int0"
  '';

  # 1 GiB /boot, one generation's kernel+initrd is ~80 MiB
  boot.loader.grub.configurationLimit = 10;
}
