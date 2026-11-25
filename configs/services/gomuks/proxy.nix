# The public name of gomuks (common.nix), proxied to the backend over
# retiolum. No login in front: gomuks' own web password, so its apps can
# connect as well. The zone's wildcard already points the name here.
{ self, ... }:
let
  common = import ./common.nix;
  backend = self.inputs.kartei.hosts.${common.backend}.nets.retiolum.ip4.addr;
in
{
  services.nginx.virtualHosts.${common.domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${backend}:${toString common.port}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      # the websocket and the SSE stream; media uploads
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 100M;
      '';
    };
  };
}
