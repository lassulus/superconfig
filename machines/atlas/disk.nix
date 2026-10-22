{
  # xerxes' NVMe, installed by the graphical nixos installer; kept as is
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/e2e38fb5-0cea-4a97-ae56-c2858ae0e07b";
    fsType = "ext4";
  };

  boot.initrd.luks.devices."luks-097e027e-ff3a-478f-8030-193de43e888f".device =
    "/dev/disk/by-uuid/097e027e-ff3a-478f-8030-193de43e888f";

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A53B-D2C9";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };
}
