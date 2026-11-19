{
  config,
  pkgs,
  ...
}:
let
  cfg = config.lass.hermes.instances.brockman;
  vars = config.clan.core.vars.generators;
in
{
  imports = [ ../../configs/hermes-agent ];

  # Hermes for brockman development with kmein, reachable over Matrix as
  # @hermes-brockman:lassul.us. Unit hermes-brockman.service, user and group
  # hermes-brockman, state in /var/lib/hermes-brockman (module defaults).
  lass.hermes.instances.brockman = {
    extraDependencyGroups = [
      "matrix"
      "anthropic"
    ];

    extraPackages = [
      pkgs.git
      pkgs.openssh
      pkgs.gh
      config.nix.package
    ];

    # Placeholder: adjust once the key in hermes-brockman-model is known.
    settings.model = {
      provider = "anthropic";
      default = "claude-opus-5-5";
    };

    # Anyone in these rooms may talk to the bot (with an @mention); add
    # the room IDs of rooms lassulus set up with kmein. Rooms with at most
    # two members count as DMs and never match.
    settings.platforms.matrix.group_allowed_chats = [ ];

    environment = {
      MATRIX_HOMESERVER = "https://matrix.lassul.us";
      MATRIX_USER_ID = "@hermes-brockman:lassul.us";
      # Also gates invites and DMs, so kmein stays off this list.
      MATRIX_ALLOWED_USERS = "@lassulus:lassul.us";
      MATRIX_E2EE_MODE = "optional";
      MATRIX_RECOVERY_KEY_OUTPUT_FILE = "${cfg.stateDir}/.hermes/matrix-recovery-key";
    };

    environmentFiles = [
      vars.hermes-brockman-matrix.files."matrix.env".path
      vars.hermes-brockman-model.files.env.path
    ];
  };

  # The agent's own credentials (ssh key, gh login of the GitHub account
  # hermes-brockman, git identity) live in its home, so it can rotate them
  # itself; the backup below keeps them.
  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";

  # SQLite files are dumped with .backup instead of copied live.
  lass.backup.state.hermes-brockman = {
    folders = [ cfg.stateDir ];
    exclude = [
      "${cfg.stateDir}/.cache"
      "${cfg.stateDir}/.hermes/cache"
      "${cfg.stateDir}/*.db"
      "${cfg.stateDir}/*.db-wal"
      "${cfg.stateDir}/*.db-shm"
    ];
    preBackup = ''
      rm -rf /var/backup/hermes-brockman
      cd ${cfg.stateDir}
      ${pkgs.findutils}/bin/find . -name '*.db' -not -path './.hermes/cache/*' -type f | while read -r f; do
        mkdir -p "/var/backup/hermes-brockman/$(dirname "$f")"
        ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" "$f" ".backup '/var/backup/hermes-brockman/$f'"
      done
    '';
    # sqlite needs the WAL/shm files next to each database
    readWritePaths = [ cfg.stateDir ];
  };

  clan.core.vars.generators.hermes-brockman-matrix = {
    prompts.matrix-access-token = {
      description = "Matrix access token for @hermes-brockman:lassul.us";
      type = "hidden";
      persist = true;
    };
    files."matrix.env" = { };
    script = ''
      echo "MATRIX_ACCESS_TOKEN=$(cat "$prompts"/matrix-access-token)" > "$out/matrix.env"
    '';
  };

  clan.core.vars.generators.hermes-brockman-model.prompts.env = {
    description = "Model provider env lines for hermes-brockman (e.g. ANTHROPIC_API_KEY=...)";
    type = "multiline-hidden";
    persist = true;
  };
}
