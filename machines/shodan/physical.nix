{
  self,
  config,
  lib,
  ...
}:
{
  imports = [
    ./config.nix
    ./disk.nix
    self.inputs.nixos-hardware.nixosModules.lenovo-thinkpad-x220
  ];

  # nixos-hardware's tp_smapi lacks the module certificate the module
  # aggregator needs, see configs/hw/signed-kmods.nix.
  disabledModules = [ "${self.inputs.nixos-hardware}/lenovo/thinkpad/tp-smapi.nix" ];
  boot.kernelModules = [ "tp_smapi" ];
  boot.extraModulePackages = [
    (import ../../configs/hw/signed-kmods.nix {
      inherit lib;
      inherit (config.boot) kernelPackages;
    }).tp_smapi
  ];

  # Disable hdapsd - not needed for SSD, and the package is broken with newer GCC
  services.hdapsd.enable = false;

  boot.loader.grub = {
    enable = true;
    device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_500GB_S2RBNX0H662201F";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  services.udev.extraRules = ''
    SUBSYSTEM=="net", ATTR{address}=="a0:88:b4:29:26:bc", NAME="wl0"
    SUBSYSTEM=="net", ATTR{address}=="f0:de:f1:0c:a7:63", NAME="et0"
    SUBSYSTEM=="net", ATTR{address}=="00:e0:4c:69:ea:71", NAME="int0"
  '';
}
