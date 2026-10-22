{
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
  security.acme.acceptTerms = true;
  security.acme.defaults.email = "acme@lassul.us";

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedTlsSettings = true;

    enableReload = true;

    # nginx defaults to one worker with 512 connections, and a proxied
    # websocket costs two of them (client + upstream). maze.lassul.us hit
    # "512 worker_connections are not enough" at ~250 players, which takes
    # down every other vhost on the box with it.
    eventsConfig = ''
      worker_connections 8192;
      multi_accept on;
    '';
    appendConfig = ''
      worker_rlimit_nofile 65536;
    '';

    # avoid nixpkgs nginx's /tmp/nginx_* compile-time defaults: under
    # systemd PrivateTmp they don't survive a host `rm -rf /tmp/*`.
    appendHttpConfig = ''
      client_body_temp_path /var/cache/nginx/client_body;
      proxy_temp_path /var/cache/nginx/proxy;
      fastcgi_temp_path /var/cache/nginx/fastcgi;
      uwsgi_temp_path /var/cache/nginx/uwsgi;
      scgi_temp_path /var/cache/nginx/scgi;
    '';

    virtualHosts.default = {
      default = true;
      locations."/".extraConfig = ''
        return 404;
      '';
      locations."= /etc/os-release".extraConfig = ''
        default_type text/plain;
        alias /etc/os-release;
      '';
      locations."~ ^/.well-known/acme-challenge/".root = "/var/lib/acme/acme-challenge";
    };
  };

  # worker_rlimit_nofile above only matters if systemd lets nginx have them.
  systemd.services.nginx.serviceConfig.LimitNOFILE = 65536;
}
