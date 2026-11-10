{
  self,
  modulesPath,
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
    self.inputs.disko.nixosModules.disko
    ./disk.nix
  ];

  # Fanless mini PC: Intel Core 3 N355 (8c), 32 GiB, 1 TB NVMe, 2x I226-V.
  # clan writes facter.json during install (which also sets this), so keep it
  # overridable.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  networking.hostId = "ac4e5011";

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.kernelParams = [
    "boot.shell_on_fail"
  ];
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Both ports are Intel I226-V (igc). Same naming as styx so configs/gg23.nix
  # applies unchanged: et0 = WAN (uplink, DHCP client), int0 = LAN (10.42.0.1).
  # Port 1 (enp2s0) is the uplink, port 2 (enp3s0) faces the gg23 LAN.
  services.udev.extraRules = ''
    SUBSYSTEM=="net", ATTR{address}=="a8:b8:e0:08:28:94", NAME="et0"
    SUBSYSTEM=="net", ATTR{address}=="a8:b8:e0:08:28:95", NAME="int0"
  '';

  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
}
