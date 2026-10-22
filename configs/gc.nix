{ config, lib, ... }:
{
  nix.gc = {
    automatic =
      !(
        lib.elem config.networking.hostName [
          "aergia"
          "ignavia"
          "mors"
          "coaxmetal"
        ]
        || config.boot.isContainer
      );
    options = "--delete-older-than 15d";
  };

  # collect garbage when the filesystem holding /nix/store is over 90% full
  systemd.services.nix-gc-disk-full = lib.mkIf (!config.boot.isContainer) {
    description = "Nix Garbage Collector on full disk";
    script = ''
      usage=$(df --output=pcent /nix/store | tail -n 1 | tr -dc 0-9)
      if [ "$usage" -gt 90 ]; then
        echo "/nix/store at $usage%, running garbage collection"
        exec ${config.nix.package.out}/bin/nix-collect-garbage --delete-older-than 15d
      fi
      echo "/nix/store at $usage%, skipping garbage collection"
    '';
    serviceConfig.Type = "oneshot";
    startAt = "hourly";
    restartIfChanged = false;
  };
  systemd.timers.nix-gc-disk-full = lib.mkIf (!config.boot.isContainer) {
    timerConfig.Persistent = true;
  };
}
