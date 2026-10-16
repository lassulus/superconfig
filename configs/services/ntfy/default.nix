let
  domain = "ntfy.lassul.us";
  port = 2586;
in
{
  # ntfy as UnifiedPush distributor for the phone. Anonymous like ntfy.sh:
  # the phone subscribes to its "up…" topics, app servers (Synapse, phonetpm
  # daemons) publish to them without an account.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://${domain}";
      listen-http = "127.0.0.1:${toString port}";
      # Visitors are identified by the address nginx appends to
      # X-Forwarded-For, not by nginx's own address.
      behind-proxy = true;
      # No attachments (the module enables them by default).
      attachment-cache-dir = "";
      # Publishers are rate limited per IP (60 requests burst, then one per
      # 5s). Synapse on this host publishes every Matrix push, so exempt
      # neoprism's own addresses (machines/neoprism/physical.nix).
      visitor-request-limit-exempt-hosts = "95.217.192.59,2a01:4f9:4a:4f1a::2";
    };
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      recommendedProxySettings = true;
      proxyWebsockets = true;
      # Subscriptions are long-lived HTTP streams / websockets with a 45s
      # keepalive; settings from ntfy's nginx example.
      extraConfig = ''
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 3m;
        proxy_send_timeout 3m;
        proxy_read_timeout 3m;
        client_max_body_size 0;
      '';
    };
  };
}
