{
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    ./config.nix
    ./disk.nix
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # ASRock Z170 Extreme4, UEFI
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules = [ "kvm-intel" ];
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  hardware.cpu.intel.updateMicrocode = true;

  # AMD Radeon (Navi 14 / RX 5500-class, PCI 1002:7340) -> amdgpu.
  #
  # amdgpu is deliberately NOT in boot.initrd.kernelModules: early-loading it
  # tears down efifb before the GPU firmware is available in stage-1, which
  # black-screens this card from the moment the kernel starts (measured: ~5min
  # to reach systemd). Let udev load amdgpu in stage-2, where the firmware is
  # present. hardware.amdgpu.initrd.enable is the same trap — it only adds the
  # module and handles no firmware.
  hardware.graphics.enable = true;
  hardware.enableRedistributableFirmware = true;
  services.xserver.videoDrivers = [ "amdgpu" ];

  # Name the onboard Intel NIC deterministically.
  services.udev.extraRules = ''
    SUBSYSTEM=="net", ATTR{address}=="70:85:c2:0e:ea:3c", NAME="et0"
  '';
}
