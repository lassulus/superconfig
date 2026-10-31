{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  port = config.lass.servicePorts.hermes-voice;
  # The gateway's webhook platform (hermes.nix), loopback only.
  webhookPort = config.services.hermes-agent.settings.platforms.webhook.extra.port;
in
{
  imports = [ ../../configs/hermes-voice-vars.nix ];

  lass.ports."8790" = "hermes-voice";

  # hermes-voice (tools/hermes-voice): live voice conversations with Hermes
  # through OpenAI's gpt-live-1. Runs next to Hermes so its API key never
  # leaves this host; reachable over retiolum and publicly as
  # https://assist.lassul.us through neoprism (configs/hermes-proxy.nix).
  #
  # SECURITY: the page drives Hermes, which has terminal tools and code
  # execution as lass (machines/coaxmetal/hermes.nix). The access token
  # (configs/hermes-voice-vars.nix) and the Android app's token
  # (hermes-voice-app below) are the gates on every API route; treat both
  # like the hermes-api key. The app takes calls from the headset button with
  # the phone locked, approvals by voice included.
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
        "http://${config.networking.hostName}.r:${toString config.lass.servicePorts.hermes-api}"
        "--hermes-key-file"
        "%d/hermes-key"
        "--openai-key-file"
        "%d/openai-key"
        "--access-token-file"
        "%d/access-token"
        "--app-token-file"
        "%d/app-token"
        "--matrix-webhook"
        "http://127.0.0.1:${toString webhookPort}/webhooks/voice-approval"
      ];
      LoadCredential = [
        "hermes-key:${config.clan.core.vars.generators.hermes-api.files."api_key".path}"
        "openai-key:${config.clan.core.vars.generators.hermes-voice-openai.files."api-key".path}"
        "access-token:${config.clan.core.vars.generators.hermes-voice.files."access-token".path}"
        "app-token:${config.clan.core.vars.generators.hermes-voice-app.files.token.path}"
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
  # toolset (end_call refuses outside voice sessions), /assist, which
  # answers approvals asked in the Matrix DM through hermes-voice
  # (authenticated with API_SERVER_KEY).
  services.hermes-agent.extraPlugins = [
    (pkgs.runCommand "hermes-voice" { } ''
      cp -r ${../../tools/hermes-voice/hermes-plugin} $out
    '')
  ];
  services.hermes-agent.environment.HERMES_VOICE_URL = "http://localhost:${toString port}";

  # How hermes-voice asks for an approval when no call can hear it, and
  # where it posts each call's transcript after the hang-up: a
  # deliver_only route on the gateway's webhook platform (hermes.nix) posts
  # the text to the Matrix home room, no agent turn.
  services.hermes-agent.settings.platforms.webhook.extra.routes.voice-approval = {
    deliver = "matrix";
    deliver_only = true;
    prompt = "{text}";
  };

  # OpenAI project key with GPT-Live access; billed per second of open voice
  # session. persist=true so the prompt value is stored once.
  clan.core.vars.generators.hermes-voice-openai.prompts.api-key = {
    description = "OpenAI API key for hermes-voice (gpt-live-1)";
    type = "hidden";
    persist = true;
  };

  # Bearer token of the Android app (tools/hermes-voice/android), checked by
  # hermes-voice next to the page's access token; the proxy passes it through
  # on assist.lassul.us/app/ without the web login (configs/hermes-proxy.nix).
  # Paste it into the app once:
  #   clan vars get coaxmetal hermes-voice-app/token
  clan.core.vars.generators.hermes-voice-app = {
    files.token = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/token"
    '';
  };

  # Signing key of the Android app (packages.hermes-voice-android); only read
  # when signing, so nothing is deployed.
  clan.core.vars.generators.hermes-voice-android-signing = {
    files.keystore.deploy = false;
    files.password.deploy = false;
    files.fingerprint.secret = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jdk17_headless
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/password"
      keytool -genkeypair -noprompt -storetype PKCS12 -keystore "$out/keystore" \
        -storepass:file "$out/password" -alias assist -dname CN=Assist \
        -keyalg RSA -keysize 4096 -validity 36500
      keytool -exportcert -rfc -keystore "$out/keystore" -storepass:file "$out/password" -alias assist |
        openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 > "$out/fingerprint"
    '';
  };
}
