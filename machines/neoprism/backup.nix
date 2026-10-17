{ config, pkgs, ... }:
{
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

  # Ensure backup directory exists for pg_dump
  systemd.tmpfiles.rules = [
    "d /var/backup 0700 root root -"
    "d /var/backup/postgresql 0700 root root -"
    "d /var/backup/parley 0700 root root -"
  ];

  services.borgbackup.jobs.hetzner = {
    paths = [
      "/var/backup"
      "/var/lib/bitwarden_rs"
      "/var/lib/htgen-cyberlocker"
      "/var/lib/htgen-paste"
      "/var/lib/matrix-synapse/media_store/local_content"
      "/var/lib/radicale"
      "/home/bot"
      "/var/vmail"
      "/var/dkim"
      "/var/sieve"
      "/var/lib/heisenbridge"
      # identity.key also lives in clan vars; the SQLite databases are
      # dumped consistently to /var/backup/parley by the preHook.
      "/var/lib/parley"
      # WBO boards (paint.lassul.us). DynamicUser + StateDirectory make
      # /var/lib/whitebophir only a symlink, so back up the real directory.
      "/var/lib/private/whitebophir"
    ];
    exclude = [
      "*.pyc"
      "/home/bot/.cache"
      "/home/bot/.nix-defexpr"
      "/home/bot/.nix-profile"
      "/var/lib/parley/*.db*"
    ];
    repo = "u550643@u550643.your-storagebox.de:/./neoprism";
    encryption.mode = "none";
    compression = "auto,zstd";
    startAt = "*-*-* 03:00:00";
    environment.BORG_RSH =
      let
        knownHostsFile = pkgs.writeText "storagebox-known-hosts" ''
          [u550643.your-storagebox.de]:23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs
        '';
      in
      "ssh -oPort=23 -oUserKnownHostsFile=${knownHostsFile} -i ${
        config.clan.core.vars.generators.borgbackup.files."borgbackup.ssh.id25519".path
      }";

    readWritePaths = [
      "/var/backup"
      "/var/lib/hedgedoc"
      # WAL-mode SQLite readers need to write the -shm file
      "/var/lib/parley"
    ];

    preHook = ''
      set -x
      # Dump matrix-synapse PostgreSQL database (14GB, compresses well)
      ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
        matrix-synapse | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/matrix-synapse.sql.gz

      # Dump bridge PostgreSQL databases — portal mappings, sessions, tokens.
      # Losing these = relogin everywhere + every existing Matrix room orphaned.
      for db in mautrix-whatsapp mautrix-signal mautrix-telegram mautrix-discord; do
        ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
          "$db" | ${pkgs.gzip}/bin/gzip > "/var/backup/postgresql/$db.sql.gz"
      done

      # Dump zitadel (id.lassul.us) PostgreSQL database: users, passkeys,
      # IdP links, OIDC apps. Its secrets are encrypted with the masterkey
      # from clan vars.
      ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
        zitadel | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/zitadel.sql.gz

      # Dump hedgedoc SQLite database safely. It uses a rollback journal and
      # writes often during the day, so wait for its locks instead of failing.
      ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" /var/lib/hedgedoc/db.sqlite ".backup /var/backup/hedgedoc.sqlite"

      # Dump parley accounts + history SQLite databases safely
      for db in parley history; do
        ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" "/var/lib/parley/$db.db" ".backup /var/backup/parley/$db.db"
      done

      # Dump timeful polls (when.lassul.us) from MongoDB
      ${pkgs.mongodb-tools}/bin/mongodump --uri=mongodb://127.0.0.1:27017 \
        --db=schej-it --gzip --archive=/var/backup/timeful.archive.gz
    '';

    prune.keep = {
      within = "1d";
      daily = 7;
      weekly = 4;
      monthly = 0;
    };
  };
}
