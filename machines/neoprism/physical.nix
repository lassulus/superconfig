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

  networking.hostId = "9c0a74ac";
  boot.kernelPackages = pkgs.zfs.latestCompatibleLinuxPackages;

  boot.loader.grub.enable = true;
  boot.loader.grub.efiSupport = true;
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "sd_mod"
  ];
  boot.kernelParams = [
    "boot.shell_on_fail"
  ];
  boot.kernelModules = [ "kvm-amd" ];
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # networking config
  networking.useNetworkd = true;
  systemd.network = {
    enable = true;
    config = {
      networkConfig.SpeedMeter = true;
    };
    netdevs.ext-br.netdevConfig = {
      Kind = "bridge";
      Name = "ext-br";
      # keep the host's NIC MAC bound to the host IP on Hetzner's switch
      MACAddress = "a8:a1:59:0f:2d:69";
    };
    networks.ext-br = {
      matchConfig.Name = "ext-br";
      address = [
        "95.217.192.59/26"
        "2a01:4f9:4a:4f1a::2/64"
      ];
      gateway = [
        "95.217.192.1"
        "fe80::1"
      ];
    };
    networks."01-enp" = {
      matchConfig.Name = "enp35s0";
      # enslave the physical NIC to ext-br; the host IP lives on the bridge now
      bridge = [ "ext-br" ];
    };
  };

  networking.useDHCP = false;
  # boot.initrd.network = {
  #   enable = true;
  #   ssh = {
  #     enable = true;
  #     authorizedKeys = [ self.keys.ssh.yubi_pgp.public ];
  #     port = 2222;
  #     hostKeys = [
  #       (<secrets/ssh.id_ed25519>)
  #       (<secrets/ssh.id_rsa>)
  #     ];
  #   };
  # };
  # boot.kernelParams = [
  #   "net.ifnames=0"
  #   "ip=dhcp"
  #   "boot.trace"
  # ];

  # 1 GiB /boot, one generation's kernel+initrd is ~80 MiB
  boot.loader.grub.configurationLimit = 10;
}
