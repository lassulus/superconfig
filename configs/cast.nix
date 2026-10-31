{ config, ... }:
{
  lass.ports = {
    "8081" = "owncast";
    ${toString config.services.owncast.rtmp-port} = "owncast-rtmp";
  };
  services.owncast.enable = true;
  services.owncast.port = config.lass.servicePorts.owncast;
  services.nginx = {
    enable = true;
    virtualHosts."cast.lassul.us" = {
      enableACME = true;
      forceSSL = true;
      locations."/".extraConfig = ''
        proxy_pass http://localhost:${toString config.services.owncast.port};
      '';
    };
  };
  networking.firewall.allowedTCPPorts = [ config.services.owncast.rtmp-port ];
}
