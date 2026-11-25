{
  self,
  modulesPath,
  lib,
  ...
}:
{
  imports = [
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
    self.inputs.disko.nixosModules.disko
    ./disk.nix
  ];

  # x86_64 KVM guest; clan writes facter.json during install (which also sets
  # this), so keep it overridable.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  networking.hostId = "5a17c0de";

  # KVM guest, legacy BIOS boot. disko registers /dev/vda as the GRUB target
  # via the EF02 partition, so don't set boot.loader.grub.device here.
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "sr_mod"
    "ahci"
  ];

  # Single static public IPv4 on the virtio NIC (matched by its MAC so the
  # kernel-assigned interface name is irrelevant). No provider IPv6.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network = {
    enable = true;
    networks."10-wan" = {
      matchConfig.MACAddress = "00:16:3c:9d:04:c1";
      address = [ "194.110.87.67/24" ];
      routes = [ { Gateway = "194.110.87.1"; } ];
      dns = [
        "8.8.8.8"
        "8.8.4.4"
      ];
    };
  };

  # /boot is on the root filesystem
  boot.loader.grub.configurationLimit = 20;
}
