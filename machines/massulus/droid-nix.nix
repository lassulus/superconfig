# droid-nix (github:lassulus/droid-nix) configuration of the phone massulus,
# flake output droidNixConfigurations.massulus. Not a clan machine: flake.nix
# hides this directory from clan, which would otherwise make it a NixOS
# machine. CI builds it on aarch64 and pushes it to cache.lassul.us
# (.github/workflows/ci.yml). On the phone:
#   droid-nix switch --flake github:lassulus/superconfig#massulus
{
  lib,
  pkgs,
  self,
  ...
}:
{
  environment.packages = with pkgs; [
    nvi
    git-phone
    libarchive
    gnugrep
    gnused
    findutils
    procps
  ];

  services.sshd.enable = true;
  services.sshd.authorizedKeys = with self.keys.ssh; [
    barnacle.public
    ignavia.public
    yubi_pgp.public
    yubi1.public
    yubi2.public
    solo2.public
  ];

  android-integration = {
    api.enable = true;
    open.enable = true;
    open-url.enable = true;
    xdg-open.enable = true;
    setup-storage.enable = true;
    wake-lock.enable = true;
    wake-unlock.enable = true;
  };

  # CI's builds, see configs/default.nix
  nix.substituters = [ "https://cache.lassul.us" ];
  nix.trustedPublicKeys = [
    (lib.removeSuffix "\n" (
      builtins.readFile (self + "/vars/per-machine/neoprism/nix-cache-signing/key.pub/value")
    ))
  ];
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  time.timeZone = "Europe/Berlin";
}
