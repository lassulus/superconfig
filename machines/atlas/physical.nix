{
  config,
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
    "e1000e"
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

  # Name the onboard Intel NIC deterministically and arm Wake-on-LAN (woken
  # by wake-atlas on coaxmetal). Not networking.interfaces.et0.wakeOnLan:
  # its .link matches OriginalName=et0, the kernel name is a different one.
  systemd.network.links."10-et0" = {
    matchConfig.PermanentMACAddress = "70:85:c2:0e:ea:3c";
    linkConfig = {
      Name = "et0";
      WakeOnLan = "magic";
    };
  };

  # Unlock the LUKS root over ssh from the LAN (retiolum is not up yet):
  # ssh -p 2222 root@<atlas' LAN ip>, then systemd-tty-ask-password-agent.
  boot.initrd.network.enable = true;
  boot.initrd.systemd.network.networks."10-et0" = {
    # the initrd has no .link renaming the NIC
    matchConfig.MACAddress = "70:85:c2:0e:ea:3c";
    DHCP = "ipv4";
    # no machine-id in the initrd: keep its lease stable across boots
    dhcpV4Config.ClientIdentifier = "mac";
  };
  boot.initrd.network.ssh = {
    enable = true;
    port = 2222;
    authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
    hostKeys = [ config.clan.core.vars.generators.initrd-ssh.files.ssh_host_ed25519_key.path ];
  };
  # A dedicated key, it lies unencrypted in the initrd on /boot. "activation"
  # makes it a plain file below secretLocation that is there when the
  # bootloader install copies it into the initrd (/run/secrets is filled
  # after that), and keeps it out of the store.
  clan.core.vars.generators.initrd-ssh = {
    files.ssh_host_ed25519_key.neededFor = "activation";
    files."ssh_host_ed25519_key.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "" -f "$out"/ssh_host_ed25519_key
    '';
  };
}
