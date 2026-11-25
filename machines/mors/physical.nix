{
  imports = [
    ./config.nix
    ../../configs/hw/x220.nix
    ../../configs/boot/universal.nix
  ];

  boot.kernelParams = [ "acpi_backlight=native" ];

  fileSystems = {
    "/bku" = {
      device = "/dev/mapper/pool-bku";
      fsType = "btrfs";
      options = [
        "defaults"
        "noatime"
        "ssd"
        "compress=lzo"
      ];
    };
    "/home/virtual" = {
      device = "/dev/mapper/pool-virtual";
      fsType = "ext4";
    };
    "/backups" = {
      device = "/dev/pool/backup";
      fsType = "ext4";
    };
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="net", DEVPATH=="/devices/pci*/*1c.1/*/net/*", NAME="wl0"
    SUBSYSTEM=="net", ATTR{address}=="3c:97:0e:37:15:d9", NAME="et0"
  '';

  #TODO activationScripts seem broken, fix them!
  #activationScripts
  #split up and move into base
  system.activationScripts.powertopTunables = ''
    #Runtime PMs
    echo 'auto' > '/sys/bus/pci/devices/0000:00:02.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:00.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1f.3/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1f.2/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1f.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1d.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1c.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1b.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1a.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:19.0/power/control'
    echo 'auto' > '/sys/bus/pci/devices/0000:00:1c.1/power/control'
  '';

  # /boot size unknown, stay small
  boot.loader.grub.configurationLimit = 5;
}
