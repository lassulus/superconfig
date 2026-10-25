# Public door to the WebDAV share on styx (configs/health-dav.nix).
{
  services.nginx.virtualHosts."health.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/dav/" = {
      recommendedProxySettings = true;
      proxyPass = "http://styx.r:8097";
      extraConfig = ''
        client_max_body_size 1g;
        proxy_request_buffering off;
      '';
    };
    locations."/".return = "404";
  };
}
