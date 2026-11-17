{
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-agent;
  vars = config.clan.core.vars.generators;
in
{
  imports = [ ../../configs/hermes-agent ];

  # Hermes for brockman development with kmein, reachable over Matrix as
  # @hermes-brockman:lassul.us. The unit keeps the module's name, hermes-agent.
  services.hermes-agent = {
    enable = true;
    user = "hermes-brockman";
    group = "hermes-brockman";
    stateDir = "/var/lib/hermes-brockman";

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

  # Tool shells and cron scopes do not see $CREDENTIALS_DIRECTORY, so ssh
  # needs the key in ~/.ssh.
  systemd.services.hermes-agent.serviceConfig = {
    LoadCredential = [ "id_ed25519:${vars.hermes-brockman-ssh.files.id_ed25519.path}" ];
    ExecStartPre = [
      "${pkgs.writeShellScript "hermes-brockman-home" ''
        set -eu
        PATH=${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.openssh}/bin
        install -d -m 0700 "$HOME/.ssh"
        install -m 0600 "$CREDENTIALS_DIRECTORY/id_ed25519" "$HOME/.ssh/id_ed25519"
        ssh-keygen -y -f "$HOME/.ssh/id_ed25519" > "$HOME/.ssh/id_ed25519.pub"
        git config --global user.name hermes-brockman
        git config --global user.email hermes-brockman@lassul.us
      ''}"
    ];
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

  clan.core.vars.generators.hermes-brockman-ssh = {
    files.id_ed25519 = { };
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "hermes-brockman@${config.networking.hostName}" -f "$out/id_ed25519"
    '';
  };
}
