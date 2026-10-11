{
  self,
  config,
  pkgs,
  ...
}:
let
  opencrow = self.inputs.opencrow.packages.${pkgs.system}.opencrow;
  pi = self.inputs.llm-agents.packages.${pkgs.system}.pi;
in
{
  users.users.bot = {
    isNormalUser = true;
    home = "/home/bot";
    createHome = true;
    group = "users";
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [
      self.keys.ssh.barnacle.public
      self.keys.ssh.yubi_pgp.public
      self.keys.ssh.termux_massulus.public
      self.keys.ssh.yubi1.public
      self.keys.ssh.yubi2.public
      self.keys.ssh.solo2.public
      self.keys.ssh.xerxes.public
      self.keys.ssh.ignavia.public
      self.keys.ssh.phonetpm_massulus.public
      self.keys.ssh.massulus.public
    ];
    packages = [
      opencrow
      pi
      pkgs.curl
      pkgs.jq
      pkgs.lynx
    ];
  };

  clan.core.vars.generators.opencrow-matrix = {
    prompts.matrix-access-token = {
      description = "Matrix access token for @opencrow:lassul.us";
      type = "hidden";
      persist = true;
    };
  };

  clan.core.vars.generators.opencrow-openrouter = {
    prompts.openrouter-api-key = {
      description = "OpenRouter API key for opencrow - get from https://openrouter.ai/keys";
      type = "hidden";
      persist = true;
    };
  };

  clan.core.vars.generators.opencrow-env = {
    dependencies = [
      "opencrow-matrix"
      "opencrow-openrouter"
    ];
    files."opencrow.env" = { };
    script = ''
      cat > "$out/opencrow.env" << EOF
      OPENCROW_MATRIX_ACCESS_TOKEN=$(cat $in/opencrow-matrix/matrix-access-token)
      OPENROUTER_API_KEY=$(cat $in/opencrow-openrouter/openrouter-api-key)
      EOF
    '';
  };

  systemd.services.opencrow = {
    description = "OpenCrow Matrix Bot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [
      opencrow
      pi
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.lynx
    ];

    environment = {
      OPENCROW_MATRIX_HOMESERVER = "https://matrix.lassul.us";
      OPENCROW_ALLOWED_USERS = "@lassulus:lassul.us";
      OPENCROW_MATRIX_USER_ID = "@opencrow:lassul.us";
      OPENCROW_MATRIX_DEVICE_ID = "AYBPKDHIDV";
      OPENCROW_PI_SESSION_DIR = "/home/bot/opencrow/sessions";
      OPENCROW_PI_WORKING_DIR = "/home/bot/opencrow";
      OPENCROW_PI_SKILLS = "${opencrow}/share/opencrow/skills/web";
      OPENCROW_PI_SKILLS_DIR = "/home/bot/skills";
      OPENCROW_PI_PROVIDER = "openrouter";
      OPENCROW_PI_MODEL = "anthropic/claude-sonnet-4";
      # OPENCROW_HEARTBEAT_INTERVAL = "10m";
      OPENCROW_SHOW_TOOL_CALLS = "1";
      OPENCROW_SOUL_FILE = "/home/bot/opencrow/SOUL.md";
      PI_CODING_AGENT_DIR = "/home/bot/opencrow/pi-agent";
    };

    serviceConfig = {
      EnvironmentFile = [
        config.clan.core.vars.generators.opencrow-env.files."opencrow.env".path
        config.clan.core.vars.generators.mailserver-bot.files."mail.env".path
      ];
      ExecStart = "${opencrow}/bin/opencrow";
      Restart = "on-failure";
      RestartSec = 10;
      User = "bot";
      Group = "users";
      WorkingDirectory = "/home/bot/opencrow";
    };
  };

  # ensure working directory exists
  systemd.tmpfiles.rules = [
    "d /home/bot/opencrow 0750 bot users -"
    "d /home/bot/opencrow/sessions 0750 bot users -"
    "d /home/bot/opencrow/pi-agent 0750 bot users -"
  ];
}
