{
  nix.settings.experimental-features = [
    # for container in builds support
    "auto-allocate-uids"
    "cgroups"
  ];

  # no longer need to pre-allocate build users for everything
  nix.settings.auto-allocate-uids = true;

  # for container in builds support (NixOS tests with `containers`), added
  # to the default features
  nix.settings.system-features = [ "uid-range" ];
}
