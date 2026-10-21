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
    ../../configs/review.nix
    ../../configs/rad.nix
    ../../configs/orca/ide.nix
    ../../configs/orca/server.nix
    ../../configs/crit.nix
    ../../configs/monitoring/server.nix
    ./strom.nix
    ./hermes.nix
    ./hermes-voice.nix
    ./backup.nix
  ];

  system.stateVersion = "24.05";

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];
  # 32 GB RAM: parallel rustc/ld builds (~10 GB each) OOM'd with max-jobs=16
  nix.settings.max-jobs = 4;

  services.tor = {
    enable = true;
    client.enable = true;
  };

  documentation.nixos.enable = true;

  environment.systemPackages = [
    pkgs.android-tools
  ];
}
