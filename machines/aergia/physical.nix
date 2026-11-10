{ pkgs, modulesPath, ... }:
{
  imports = [
    ./config.nix
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disk.nix
  ];

  networking.hostId = "deadbeef";
  # boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.grub = {
    enable = true;
    device = "/dev/nvme0n1";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = [
    # use less power with pstate
    "amd_pstate=passive"

    # suspend
    "resume_offset=178345675"
  ];

  boot.kernelModules = [
    # Enables the amd cpu scaling https://www.kernel.org/doc/html/latest/admin-guide/pm/amd-pstate.html
    # On recent AMD CPUs this can be more energy efficient.
    "amd-pstate"
    "kvm-amd"
  ];

  # hardware.cpu.amd.updateMicrocode = true;

  services.xserver.videoDrivers = [
    "amdgpu"
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "thunderbolt"
    "xhci_pci"
    "usbhid"
  ];

  boot.initrd.kernelModules = [
    "amdgpu"
  ];

  environment.systemPackages = [
    pkgs.vulkan-tools
  ];

  # corectrl
  programs.corectrl = {
    enable = true;
    gpuOverclock = {
      enable = true;
      ppfeaturemask = "0xffffffff";
    };
  };
  users.users.mainUser.extraGroups = [ "corectrl" ];

  # keyboard quirks
  services.xserver.displayManager.sessionCommands = ''
    ${pkgs.xorg.xmodmap}/bin/xmodmap -e 'keycode 96 = F12 Insert F12 F12' # rebind shift + F12 to shift + insert
  '';
  services.udev.extraHwdb = # sh
    ''
      # disable back buttons
      evdev:input:b0003v2F24p0135* # /dev/input/event2
        KEYBOARD_KEY_70026=reserved
        KEYBOARD_KEY_70027=reserved
    '';

  # update cpu microcode
  hardware.cpu.amd.updateMicrocode = true;

  hardware.graphics.enable = true;

  # suspend to disk
  swapDevices = [
    {
      device = "/swapfile";
    }
  ];
  boot.resumeDevice = "/dev/mapper/aergia1";
  services.logind.lidSwitch = "suspend-then-hibernate";
  # systemd.sleep.extraConfig = ''
  #   HibernateDelaySec=1800
  # '';

  # firefox touchscreen support
  environment.sessionVariables.MOZ_USE_XINPUT2 = "1";

  # enable thunderbolt
  services.hardware.bolt.enable = true;

  # reinit usb after docking station connect
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", ACTION=="change", RUN+="${pkgs.dash}/bin/dash -c 'echo 0 > /sys/bus/usb/devices/usb9/authorized; echo 1 > /sys/bus/usb/devices/usb9/authorized'"
  '';
}
