# Baseline for the public nginx hosts (neoprism, starkstrom).
{ config, lib, ... }:
{
  # HSTS on every vhost that only serves HTTPS (forceSSL/onlySSL), set here
  # once instead of per vhost. addSSL vhosts serve plain HTTP on purpose
  # (radio streams, http://lassul.us, ...), HSTS would make browsers stop
  # using it, so they don't get it. No includeSubDomains/preload: *.lassul.us
  # has names that aren't HTTPS-only (or not served here at all).
  #
  # add_header in a location drops every add_header of the server block, and
  # many locations here set their own. `add_header_inherit merge` (nginx
  # >= 1.29.3) makes the locations below append the server's headers to
  # theirs instead; that rule is itself inherited, so it reaches nested
  # locations and locations written into extraConfig as well.
  options.services.nginx.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config.extraConfig = lib.mkIf (config.forceSSL || config.onlySSL) ''
            add_header Strict-Transport-Security $hsts_header always;
            add_header_inherit merge;
          '';
        }
      )
    );
  };

  config = {
    lass.ports = {
      ${toString config.services.nginx.defaultHTTPListenPort} = "nginx-http";
      ${toString config.services.nginx.defaultSSLListenPort} = "nginx-https";
    };
    networking.firewall.allowedTCPPorts = [
      config.lass.servicePorts.nginx-http
      config.lass.servicePorts.nginx-https
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
      #
      # $hsts_header (HSTS above): empty, so not sent, when the proxied app
      # already sends its own Strict-Transport-Security; two of them would
      # be one too many, and the app knows its policy best.
      appendHttpConfig = ''
        client_body_temp_path /var/cache/nginx/client_body;
        proxy_temp_path /var/cache/nginx/proxy;
        fastcgi_temp_path /var/cache/nginx/fastcgi;
        uwsgi_temp_path /var/cache/nginx/uwsgi;
        scgi_temp_path /var/cache/nginx/scgi;

        map $upstream_http_strict_transport_security $hsts_header {
          "" "max-age=31536000";
          default "";
        }
      '';

      # Catch-all for names no other vhost has. Port 80: 404, except the ACME
      # webroot and /etc/os-release (plain-IP access). TLS: rejectSSL makes it
      # the default_server on 443 too, with ssl_reject_handshake, so an
      # unknown name (*.lassul.us is a CNAME to here) gets a handshake alert
      # instead of the first vhost's certificate and site.
      virtualHosts.default = {
        default = true;
        rejectSSL = true;
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
  };
}
