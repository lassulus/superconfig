{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.lass.backup;
  states = lib.attrValues cfg.state;
  key = config.clan.core.vars.generators.borgbackup.files."borgbackup.ssh.id25519".path;

  # Runs every state's hook in its own script, keeps going when one fails
  # and fails at the end if any did.
  runHooks =
    hook:
    pkgs.writeShellScript "backup-${hook}" ''
      failed=()
      ${lib.concatMapStrings (state: ''
        echo "backup: ${hook} ${state.name}"
        ${pkgs.writeShellScript "backup-${hook}-${state.name}" ''
          set -xeo pipefail
          ${state.${hook}}
        ''} || failed+=(${lib.escapeShellArg state.name})
      '') (lib.filter (state: state.${hook} != null) states)}
      if [ ''${#failed[@]} -gt 0 ]; then
        echo "backup: ${hook} failed for: ''${failed[*]}" >&2
        exit 1
      fi
    '';
in
{
  options.lass.backup = {
    repo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "user@backup.example.com:/./machine";
      description = ''
        Borg repository the machine backs up to. Without it no backup job is
        generated, so modules can declare their state everywhere.
      '';
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
    };

    knownHosts = lib.mkOption {
      type = lib.types.lines;
      description = "known_hosts lines pinning the host key of the repo's server.";
    };

    state = lib.mkOption {
      default = { };
      description = ''
        Backup needs of a service, declared next to it. Dumps go to
        /var/backup, which is always backed up.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                default = name;
              };
              folders = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              exclude = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "borg exclude patterns.";
              };
              preBackup = lib.mkOption {
                type = lib.types.nullOr lib.types.lines;
                default = null;
                description = ''
                  Runs before the backup inside the read-only borg unit (as
                  root), e.g. to dump a database to /var/backup. If it fails,
                  no backup is made and the job fails.
                '';
              };
              postBackup = lib.mkOption {
                type = lib.types.nullOr lib.types.lines;
                default = null;
                description = ''
                  Runs as root after the backup, also when it failed, e.g. to
                  start a service stopped by preBackup.
                '';
              };
              readWritePaths = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Paths preBackup needs to write to.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.repo != null) {
    clan.core.vars.generators.borgbackup = {
      files."borgbackup.ssh.id25519" = { };
      files."borgbackup.ssh.id25519.pub".secret = false;
      runtimeInputs = with pkgs; [
        coreutils
        openssh
      ];
      script = ''
        ssh-keygen -t ed25519 -N "" -f $out/borgbackup.ssh.id25519
      '';
    };

    systemd.tmpfiles.rules = [ "d /var/backup 0700 root root -" ];

    # Archives are named and pruned by <hostname>-<job>; another job name
    # would leave the existing archives unpruned.
    services.borgbackup.jobs.hetzner = {
      inherit (cfg) repo;
      paths = lib.unique ([ "/var/backup" ] ++ lib.concatMap (state: state.folders) states);
      exclude = lib.unique ([ "*.pyc" ] ++ lib.concatMap (state: state.exclude) states);
      readWritePaths = lib.unique (
        [ "/var/backup" ] ++ lib.concatMap (state: state.readWritePaths) states
      );
      preHook = "${runHooks "preBackup"}";
      encryption.mode = "none";
      compression = "auto,zstd";
      startAt = "*-*-* 03:00:00";
      environment.BORG_RSH = "ssh -oPort=${toString cfg.sshPort} -oUserKnownHostsFile=${pkgs.writeText "backup-known-hosts" cfg.knownHosts} -i ${key}";
      prune.keep = {
        within = "1d";
        daily = 7;
        weekly = 4;
        monthly = 0;
      };
    };

    systemd.services.borgbackup-job-hetzner.serviceConfig.ExecStopPost = lib.mkIf (lib.any (
      state: state.postBackup != null
    ) states) [ "+${runHooks "postBackup"}" ];
  };
}
