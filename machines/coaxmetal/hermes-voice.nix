{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  port = 8790;
  # The gateway's webhook platform (hermes.nix), loopback only.
  webhookPort = 8644;
in
{
  # hermes-voice (tools/hermes-voice): live voice conversations with Hermes
  # through OpenAI's gpt-live-1. Runs next to Hermes so its API key never
  # leaves this host; reachable over retiolum and publicly as
  # https://assist.lassul.us through neoprism (configs/hermes-proxy.nix).
  #
  # SECURITY: the page drives Hermes, which has terminal tools and code
  # execution as lass (machines/coaxmetal/hermes.nix). The access token below
  # is the gate on every API route; treat it like the hermes-api key.
  systemd.services.hermes-voice = {
    description = "hermes-voice: live voice conversations with Hermes";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "hermes-agent.service"
    ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.hermes-voice)
        "--listen"
        "[::]:${toString port}"
        # The API server binds the retiolum address (hermes.nix), not
        # loopback; traffic to the host's own address goes through lo.
        "--hermes-url"
        "http://${config.networking.hostName}.r:8642"
        "--hermes-key-file"
        "%d/hermes-key"
        "--openai-key-file"
        "%d/openai-key"
        "--access-token-file"
        "%d/access-token"
        "--matrix-webhook"
        "http://127.0.0.1:${toString webhookPort}/webhooks/voice-approval"
      ];
      LoadCredential = [
        "hermes-key:${config.clan.core.vars.generators.hermes-api.files."api_key".path}"
        "openai-key:${config.clan.core.vars.generators.hermes-voice-openai.files."api-key".path}"
        "access-token:${config.clan.core.vars.generators.hermes-voice.files."access-token".path}"
      ];
      DynamicUser = true;
      Restart = "on-failure";
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
    };
  };

  # Only retiolum: neoprism's proxy and devices on the mesh. Every other
  # interface keeps the default DROP (configs/default.nix).
  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];

  # hermes-voice's side in the gateway (tools/hermes-voice/hermes-plugin): the
  # matrix_dm_send and end_call tools, on for every platform like any plugin
  # toolset (end_call refuses outside voice sessions), and /assist, which
  # answers approvals asked in the Matrix DM through hermes-voice
  # (authenticated with API_SERVER_KEY).
  services.hermes-agent.extraPlugins = [
    (pkgs.runCommand "hermes-voice" { } ''
      cp -r ${../../tools/hermes-voice/hermes-plugin} $out
    '')
  ];
  services.hermes-agent.environment.HERMES_VOICE_URL = "http://localhost:${toString port}";

  # How hermes-voice asks for an approval when no call can hear it: a
  # deliver_only route posts the text to the Matrix home room through the
  # gateway, no agent turn. Signed with WEBHOOK_SECRET, which is the API
  # server key (hermes-env in hermes.nix), so no secret is added.
  services.hermes-agent.settings.platforms.webhook = {
    enabled = true;
    extra = {
      host = "127.0.0.1";
      port = webhookPort;
      routes.voice-approval = {
        deliver = "matrix";
        deliver_only = true;
        prompt = "{text}";
      };
    };
  };

  # OpenAI project key with GPT-Live access; billed per second of open voice
  # session. persist=true so the prompt value is stored once.
  clan.core.vars.generators.hermes-voice-openai.prompts.api-key = {
    description = "OpenAI API key for hermes-voice (gpt-live-1)";
    type = "hidden";
    persist = true;
  };

  # What the page sends as its bearer token. Read it out for the phone with
  #   clan vars get coaxmetal hermes-voice/access-token
  clan.core.vars.generators.hermes-voice = {
    files."access-token" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/access-token"
    '';
  };
}
