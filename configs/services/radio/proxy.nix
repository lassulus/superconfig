{ config, ... }:
{
  lass.ports."8000" = "radio-redirect";
  services.nginx.virtualHosts."radio.lassul.us" = {
    enableACME = true;
    addSSL = true;
    locations."/" = {
      # recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = "http://radio.r";
      extraConfig = ''
        proxy_set_header Host radio.r;
        # get source ip for weather reports
        proxy_set_header user-agent "$http_user_agent; client-ip=$remote_addr";
      '';
    };
    locations."/wish" = {
      # recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = "http://radio.r:8002/wish";
      extraConfig = ''
        proxy_set_header Host radio.r;
        # get source ip for weather reports
        proxy_set_header user-agent "$http_user_agent; client-ip=$remote_addr";
      '';
    };
    locations."/all_tracks" = {
      # recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = "http://radio.r:8002/all_tracks";
      extraConfig = ''
        proxy_set_header Host radio.r;
        # get source ip for weather reports
        proxy_set_header user-agent "$http_user_agent; client-ip=$remote_addr";
      '';
    };
  };
  services.nginx.virtualHosts.radio-redirect = {
    listen = [
      {
        addr = "0.0.0.0";
        port = config.lass.servicePorts.radio-redirect;
      }
      {
        addr = "[::]";
        port = config.lass.servicePorts.radio-redirect;
      }
    ];
    locations."/".return = "301 http://radio.lassul.us$request_uri";
  };
  networking.firewall.allowedTCPPorts = [ config.lass.servicePorts.radio-redirect ];
}
