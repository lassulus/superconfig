{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.services.jitsi-meet) hostName;
  vars = config.clan.core.vars.generators.jitsi-matrix-relay.files;
in
{
  lass.ports."9899" = "jitsi-matrix-relay";

  # Relays the chat of jitsi.lassul.us/space and #space:lassul.us both ways
  # and adds a widget to the Matrix room that shows who is in the call and
  # joins it, which needs the bot (@jitsi:lassul.us) to have the power level
  # for state events.
  clan.core.vars.generators.jitsi-matrix-relay = {
    files."registration.yaml".owner = "matrix-synapse";
    files.as-token = { };
    files.hs-token = { };
    runtimeInputs = [ pkgs.pwgen ];
    script = ''
      pwgen -s 64 1 | tr -d '\n' > $out/as-token
      pwgen -s 64 1 | tr -d '\n' > $out/hs-token
      cat > $out/registration.yaml <<EOF
      id: jitsi-matrix-relay
      url: http://127.0.0.1:${toString config.lass.servicePorts.jitsi-matrix-relay}
      as_token: $(cat $out/as-token)
      hs_token: $(cat $out/hs-token)
      sender_localpart: jitsi
      rate_limited: false
      namespaces:
        users: []
        aliases: []
        rooms: []
      EOF
    '';
  };
  services.matrix-synapse.settings.app_service_config_files = [ vars."registration.yaml".path ];

  systemd.services.jitsi-matrix-relay = {
    description = "Chat relay between ${hostName}/space and #space:lassul.us";
    wantedBy = [ "multi-user.target" ];
    after = [
      "matrix-synapse.service"
      "prosody.service"
      "jicofo.service"
    ];
    environment = {
      JITSI_DOMAIN = hostName;
      JITSI_ROOM = "space";
      JITSI_NICK = "Matrix";
      XMPP_DOMAIN = "guest.${hostName}";
      XMPP_HOST = "127.0.0.1";
      MATRIX_HOMESERVER = "http://[::1]:${toString config.lass.servicePorts.matrix-synapse}";
      MATRIX_ROOM = "#space:lassul.us";
      MATRIX_LOCALPART = "jitsi";
      MATRIX_AS_TOKEN_FILE = "%d/as-token";
      MATRIX_HS_TOKEN_FILE = "%d/hs-token";
      LISTEN_PORT = toString config.lass.servicePorts.jitsi-matrix-relay;
      WIDGET_URL = "https://${hostName}/matrix/space/";
    };
    serviceConfig = {
      ExecStart = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.jitsi-matrix-relay;
      DynamicUser = true;
      LoadCredential = [
        "as-token:${vars.as-token.path}"
        "hs-token:${vars.hs-token.path}"
      ];
      Restart = "always";
      RestartSec = 10;
    };
  };
  services.nginx.virtualHosts.${hostName}.locations."^~ /matrix/space/" = {
    proxyPass = "http://127.0.0.1:${toString config.lass.servicePorts.jitsi-matrix-relay}/widget/";
    # the participant list is a stream of server-sent events
    extraConfig = "proxy_buffering off;";
  };
}
