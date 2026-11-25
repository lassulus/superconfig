{
  imports = [
    ./config.nix
    ./disk.nix
  ];
  networking.useDHCP = true;

  # 512 MiB /boot, one generation's kernel+initrd is ~80 MiB
  boot.loader.grub.configurationLimit = 4;
}
