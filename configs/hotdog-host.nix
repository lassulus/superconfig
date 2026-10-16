{ config, pkgs, ... }:
{
  lass.sync-containers3.containers.hotdog = {
    sshKey = config.clan.core.vars.generators.hotdog-container.files."hotdog.sync.key".path;
    startCommand = ''
      export PATH=$PATH:${pkgs.git}/bin
      ln -sfrT /var/lib/var_src /var/src
      until ${pkgs.dig.host}/bin/host github.com; do sleep 1; done
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild --refresh --flake 'git+https://github.com/krebs/stockholm?submodules=1#hotdog' switch --no-write-lock-file
    '';
  };
  containers.hotdog.bindMounts."/var/lib" = {
    hostPath = "/var/lib/sync-containers3/hotdog/state";
    isReadOnly = false;
  };
  clan.core.vars.generators.hotdog-container = {
    files."hotdog.sync.key" = { };
    files."hotdog.sync.pub".secret = false;
    runtimeInputs = with pkgs; [
      coreutils
      openssh
    ];
    script = ''
      ssh-keygen -t ed25519 -N "" -f "$out"/hotdog.sync.key
      mv "$out"/hotdog.sync.key.pub "$out"/hotdog.sync.pub
    '';
  };
}
