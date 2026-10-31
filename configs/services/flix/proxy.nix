{ self, pkgs, ... }:
{
  imports = [ ./transmission-proxy.nix ];

  # POST → ipfs-upload backend (writes file to /var/lib/ipfs/download/<path>
  # and returns the CID). Anything else → the kubo gateway.
  services.nginx.upstreams.ipfs-gateway.servers."127.0.0.1:8089" = { };
  services.nginx.upstreams.ipfs-upload.servers."127.0.0.1:8090" = { };
  services.nginx.appendHttpConfig = ''
    map $request_method $ipfs_lassul_upstream {
      default ipfs-gateway;
      POST    ipfs-upload;
    }
  '';

  services.nginx.virtualHosts."ipfs.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://$ipfs_lassul_upstream";
      recommendedProxySettings = true;
      extraConfig = ''
        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
      '';
    };
  };
  services.nginx.virtualHosts."flix.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      # jellyfin only listens on IPv4; yellow.r also resolves to its
      # retiolum AAAA, which nginx round-robins into -> intermittent
      # 502 "no live upstreams". Pin the v4 address.
      proxyPass = "http://${self.inputs.kartei.hosts.yellow.nets.retiolum.ip4.addr}:8096";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };
  services.nginx.virtualHosts."flex.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://radar.r:7878";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_basic "Restricted Content";
        auth_basic_user_file ${pkgs.writeText "flix-user-pass" ''
          krebs:$apr1$1Fwt/4T0$YwcUn3OBmtmsGiEPlYWyq0
        ''};
      '';
    };
  };
  services.nginx.virtualHosts."flux.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://sonar.r:8989";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_basic "Restricted Content";
        auth_basic_user_file ${pkgs.writeText "flix-user-pass" ''
          krebs:$apr1$1Fwt/4T0$YwcUn3OBmtmsGiEPlYWyq0
        ''};
      '';
    };
  };
  services.nginx.virtualHosts."flax.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://yellow.r";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_basic "Restricted Content";
        auth_basic_user_file ${pkgs.writeText "flix-user-pass" ''
          krebs:$apr1$1Fwt/4T0$YwcUn3OBmtmsGiEPlYWyq0
        ''};
      '';
    };
  };
  services.nginx.virtualHosts."flox.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://yellow.r:5055";
      proxyWebsockets = true;
      recommendedProxySettings = true;
    };
  };
}
