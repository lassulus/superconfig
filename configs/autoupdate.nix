{
  config,
  lib,
  pkgs,
  ...
}:
let
  flake = "github:lassulus/superconfig";

  # The revision the guard checked; the upgrade is pinned to it, so the
  # revision recorded afterwards is the one actually switched to.
  revFile = "/run/nixos-upgrade/rev";

  # system.autoUpgrade switches to whatever the flake currently evaluates to,
  # forwards or backwards. A machine deployed from an unpushed local checkout
  # therefore gets reverted to the older remote HEAD on the next timer run.
  # Refuse to move backwards in time: only upgrade to a revision committed
  # after the running system was deployed. The deploy time is when its profile
  # generation was created (/run/current-system's mtime if no generation points
  # at it); the source's own lastModified is no use, since `clan machines
  # update` builds from a path: flake, which has none.
  guard = pkgs.writeShellApplication {
    name = "autoupgrade-forward-only";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      system=$(readlink -f /run/current-system)
      deployed=0
      for link in /nix/var/nix/profiles/system-*-link; do
        if [ "$(readlink -f "$link")" = "$system" ]; then
          created=$(stat -c %Y "$link")
          if [ "$created" -gt "$deployed" ]; then deployed=$created; fi
        fi
      done
      if [ "$deployed" -eq 0 ]; then deployed=$(stat -c %Y /run/current-system); fi
      if ! meta=$(nix flake metadata --refresh --json ${lib.escapeShellArg flake}); then
        echo "autoupgrade: cannot reach ${flake}; letting nixos-upgrade report the error"
        exit 0
      fi
      remote=$(jq -r '.lastModified // 0' <<<"$meta")
      if [ "$remote" -gt "$deployed" ]; then
        jq -r .revision <<<"$meta" >${revFile}
        exit 0
      fi
      echo "autoupgrade: ${flake} is at $remote, running system was deployed at $deployed; skipping"
      exit 1
    '';
  };
in
{
  system.autoUpgrade = {
    enable = true;
    # Goes into the nixos-upgrade script unquoted, so the shell expands the
    # pinned revision. Without a rev file (guard could not reach the flake)
    # the ref stays unpinned and the recorded revision becomes unknown.
    flake = "${flake}/$(cat ${revFile} 2>/dev/null)";
    randomizedDelaySec = "6h";
  };

  systemd.services.nixos-upgrade.serviceConfig = {
    RuntimeDirectory = "nixos-upgrade";
    ExecCondition = lib.getExe guard;
    # Only runs after a successful upgrade. Read by the monitoring agent.
    ExecStartPost = lib.getExe (
      pkgs.writeShellApplication {
        name = "autoupgrade-record-revision";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          rev=$(cat ${revFile} 2>/dev/null || echo unknown)
          echo "$rev" >/var/lib/superconfig-revision.tmp
          mv /var/lib/superconfig-revision.tmp /var/lib/superconfig-revision
        '';
      }
    );
  };
}
