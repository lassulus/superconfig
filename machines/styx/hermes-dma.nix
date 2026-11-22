{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.lass.hermes.instances.dma;
  vars = config.clan.core.vars.generators;

  # Telegram user IDs of lass and Domi (numeric, e.g. from @userinfobot).
  # Only they may talk to the bot, in DMs and in groups. Placeholder until
  # the IDs are known; while empty the bot authorizes nobody (a DM gets a
  # pairing code that only `hermes pairing approve` on styx can accept).
  allowedUsers = [
    "162136400" # lassulus
    "184810339" # Domi A.
  ];
  # Chat ID of the Telegram group with lass and Domi (negative, -100…). The
  # bot ignores every other group. Placeholder until the group exists; while
  # empty there is no group restriction (allowedUsers still applies).
  allowedChats = [
    "-5584216578" # group "dma.lassul.us"
  ];
in
{
  imports = [ ../../configs/hermes-agent ];

  # Hermes for administrating the NixOS server dma.lassul.us together with
  # Domi, as a Telegram bot (BotFather token) in a Telegram group with lass
  # and Domi; no Matrix. Unit hermes-dma.service, user and group hermes-dma,
  # state in /var/lib/hermes-dma (module defaults). The default package
  # already ships the "messaging" (python-telegram-bot) and "anthropic"
  # groups; a platform only starts when its credentials are set, so with no
  # MATRIX_* env Matrix stays off.
  lass.hermes.instances.dma = {
    extraPackages = [
      pkgs.git
      pkgs.openssh
      pkgs.gh
      config.nix.package
      pkgs.nixos-anywhere
      pkgs.nixos-rebuild
      # Tangled CLI (PRs/issues on the dma.lassul.us repo); logged in with an
      # app password, credentials in ~/.local/share/tg (state dir, backed up)
      self.packages.${pkgs.stdenv.hostPlatform.system}.tg
    ];

    # The group is one shared admin conversation: lass and Domi talk to the
    # same session instead of one per sender (Hermes' default).
    settings.group_sessions_per_user = false;

    settings.model = {
      provider = "anthropic";
      default = "claude-opus-5-5";
    };

    # The bot gets every group message (BotFather privacy mode is off), so
    # the shared session has the whole conversation. Messages addressed to
    # someone else are answered with the silence marker, which Hermes drops.
    settings.telegram.channel_prompts = lib.genAttrs allowedChats (_: ''
      Every message in this group reaches you, also those not meant for you.
      If a message is addressed to another person (starts with their name or
      @handle, e.g. "Domi: ..." or "@lassulus ...", or is a reply to another
      person's message), take it in as context and answer with exactly
      [SILENT]. Answer everything else.
    '');

    environment = {
      TELEGRAM_REQUIRE_MENTION = "false";
    }
    # Platform-wide sender allowlist (DMs and groups). Deliberately no
    # TELEGRAM_GROUP_ALLOWED_CHATS: that would authorize every member of the
    # group, not just lass and Domi.
    // lib.optionalAttrs (allowedUsers != [ ]) {
      TELEGRAM_ALLOWED_USERS = lib.concatStringsSep "," allowedUsers;
    }
    # Groups the bot responds in at all; others only in guest mode, which
    # stays off.
    // lib.optionalAttrs (allowedChats != [ ]) {
      TELEGRAM_ALLOWED_CHATS = lib.concatStringsSep "," allowedChats;
    };

    # The activation script (root) copies these into $HERMES_HOME/.env, so
    # hermes-dma shares hermes-brockman's model token.
    environmentFiles = [
      vars.hermes-dma-telegram.files."telegram.env".path
      vars.hermes-brockman-model.files.env.path
    ];
  };

  # The agent's own credentials (ssh key for root@dma.lassul.us, gh login,
  # git identity) live in its home, so it can rotate them itself; the backup
  # below keeps them.

  # SQLite files are dumped with .backup instead of copied live.
  lass.backup.state.hermes-dma = {
    folders = [ cfg.stateDir ];
    exclude = [
      "${cfg.stateDir}/.cache"
      "${cfg.stateDir}/.hermes/cache"
      "${cfg.stateDir}/*.db"
      "${cfg.stateDir}/*.db-wal"
      "${cfg.stateDir}/*.db-shm"
    ];
    preBackup = ''
      rm -rf /var/backup/hermes-dma
      cd ${cfg.stateDir}
      ${pkgs.findutils}/bin/find . -name '*.db' -not -path './.cache/*' -not -path './.hermes/cache/*' -type f | while read -r f; do
        mkdir -p "/var/backup/hermes-dma/$(dirname "$f")"
        ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" "$f" ".backup '/var/backup/hermes-dma/$f'"
      done
    '';
    # sqlite needs the WAL/shm files next to each database
    readWritePaths = [ cfg.stateDir ];
  };

  clan.core.vars.generators.hermes-dma-telegram = {
    prompts.bot-token = {
      description = "Telegram bot token (from @BotFather) for hermes-dma";
      type = "hidden";
      persist = true;
    };
    files."telegram.env" = { };
    script = ''
      echo "TELEGRAM_BOT_TOKEN=$(cat "$prompts"/bot-token)" > "$out/telegram.env"
    '';
  };
}
