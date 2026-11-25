{
  self,
  modulesPath,
  lib,
  ...
}:

{
  imports = [
    self.inputs.disko.nixosModules.disko
    ./disk.nix
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "ehci_pci"
    "ahci"
    "xhci_pci"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.initrd.kernelModules = [ "dm-snapshot" ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  swapDevices = [ ];

  nix.maxJobs = lib.mkDefault 4;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

  #weird bug with nixos-enter
  services.logrotate.enable = false;

  # 25 GiB /boot
  boot.loader.grub.configurationLimit = 100;
}
