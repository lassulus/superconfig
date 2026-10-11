{ ... }:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/desktops/qtile/nixos.nix
    ../../configs/pipewire.nix
    ../../configs/network-manager.nix
    ../../configs/yellow-mounts/samba.nix
    ../../configs/consul.nix
    ../../configs/snapclient.nix
    ../../configs/sigexec/executor.nix
    ../../configs/rad.nix
    ../../configs/phonetpm-ssh.nix
  ];

  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchDocked = "ignore";
  nix.trustedUsers = [
    "root"
    "lass"
  ];
  system.stateVersion = "22.05";
}
