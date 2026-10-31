{ pkgs, ... }:
let
  domain = "paint.lassul.us";
  port = 3092;
in
{
  lass.ports.${toString port} = "paint";

  # WBO collaborative whiteboard. Public like the pad: anyone with the link to
  # /boards/<name> can draw, boards are kept as JSON in the state dir.
  systemd.services.whitebophir = {
    description = "WBO collaborative whiteboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = {
      PORT = toString port;
      HOST = "127.0.0.1";
      WBO_HISTORY_DIR = "/var/lib/whitebophir";
    };
    serviceConfig = {
      ExecStart = "${pkgs.whitebophir}/bin/whitebophir";
      DynamicUser = true;
      StateDirectory = "whitebophir";
      Restart = "always";
      MemoryMax = "1G";
    };
  };

  # DynamicUser + StateDirectory make /var/lib/whitebophir only a symlink
  lass.backup.state.whitebophir.folders = [ "/var/lib/private/whitebophir" ];

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      recommendedProxySettings = true;
      # socket.io
      proxyWebsockets = true;
    };
  };
}
