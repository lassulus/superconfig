{ self, pkgs, ... }:

{
  imports = [
    ../../configs
    ../../configs/mouse.nix
    ../../configs/retiolum.nix
    ../../configs/desktops/sway/default.nix
    self.wrapperModules.workspace-manager
    ../../configs/pipewire.nix
    ../../configs/network-manager.nix
    ../../configs/snapclient.nix
    ../../configs/consul.nix
    ../../configs/autoupdate.nix
    ../../configs/sigexec/executor.nix
    ../../configs/rad.nix
    ../../configs/phonetpm-ssh.nix
  ];

  lass.workspace-manager.enable = true;

  environment.systemPackages = [ pkgs.chromium ];

  # users.users.lass.openssh.authorizedKeys = [ self.inputs.kartei.users.mic92.pubkey ];
  system.stateVersion = "22.05";
}
