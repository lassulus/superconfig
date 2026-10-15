{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/ssh-redirect.nix
    ../../configs/autoupdate.nix
    ./ipfs.nix
    ./ipfs-endpoint.nix
  ];

  system.stateVersion = "25.11";
}
