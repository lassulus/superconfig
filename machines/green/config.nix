{
  config,
  pkgs,
  ...
}:
{
  clan.core.vars.password-store.secretLocation = "/var/state/secret-vars";

  imports = [
    ../../configs
    ../../configs/retiolum.nix

    ../../configs/syncthing.nix

    ../../configs/pass.nix

    # disabled: eternal-terminal 7.0.0 fails to build in the current nixpkgs
    # (cmake_pch.hxx.gch error)
    # ../../configs/et-server.nix

    ../../configs/atuin-server.nix
    ../../configs/autoupdate.nix
  ];

  lass.sync-containers3.inContainer = {
    enable = true;
    pubkey = config.clan.core.vars.generators.green-container.files."green.sync.pub".path;
  };

  clan.core.vars.generators.green-container = {
    files."green.sync.key" = { };
    files."green.sync.pub".secret = false;
    runtimeInputs = with pkgs; [
      coreutils
      openssh
    ];
    script = ''
      ssh-keygen -t ed25519 -N "" -f "$out"/green.sync.key
      mv "$out"/green.sync.key.pub "$out"/green.sync.pub
    '';
  };

  systemd.tmpfiles.rules = [
    "d /home/lass/.local/share 0700 lass users -"
    "d /home/lass/.local 0700 lass users -"
    "d /home/lass/.config 0700 lass users -"

    "d /var/state/lass_ssh 0700 lass users -"
    "L+ /home/lass/.ssh - - - - ../../var/state/lass_ssh"
    "d /var/state/lass_gpg 0700 lass users -"
    "L+ /home/lass/.gnupg - - - - ../../var/state/lass_gpg"
    "d /var/state/lass_sync 0700 lass users -"
    "L+ /home/lass/sync - - - - ../../var/state/lass_sync"

    "d /var/state/git 0700 git nogroup -"
    "L+ /var/lib/git - - - - ../../var/state/git"

    "d /var/state/zerotier-one 0700 root root -"
    "L+ /var/lib/zerotier-one - - - - ../../var/state/zerotier-one"
  ];

  # workaround for ssh access from yubikey via android
  services.openssh.extraConfig = ''
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
  '';

  environment.systemPackages = [
    pkgs.rbw
  ];
}
