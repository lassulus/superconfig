{
  pkgs,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/pipewire.nix
    ../../configs/browsers.nix
    ../../configs/network-manager.nix
    ../../configs/syncthing.nix
    ../../configs/games.nix
    ../../configs/steam.nix
    ../../configs/wine.nix
    ../../configs/yellow-mounts/samba.nix
    ../../configs/review.nix
    ../../configs/sigexec/executor.nix
    ../../configs/rad.nix
    ../../configs/orca/ide.nix
    ../../configs/orca/server.nix
    ../../configs/crit.nix
    ../../configs/monitoring/server.nix
    ./strom.nix
    ./hermes.nix
    ./hermes-voice.nix
  ];

  system.stateVersion = "24.05";

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  services.tor = {
    enable = true;
    client.enable = true;
  };

  documentation.nixos.enable = true;

  environment.systemPackages = [
    pkgs.android-tools
  ];
}
