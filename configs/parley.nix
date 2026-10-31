{ config, lib, ... }:
let
  domain = "parley.lassul.us";
  # "127.0.0.1:6667" -> "6667"
  listenPort = addr: lib.last (lib.splitString ":" addr);
in
{
  lass.ports = {
    ${listenPort config.lass.parley.settings.PARLEY_HTTP_LISTEN} = "parley";
    ${listenPort config.lass.parley.settings.PARLEY_IRC_LISTEN} = "parley-irc";
    "6697" = "parley-ircs";
  };

  # parley: federated chat that speaks plain IRC. Identities are
  # nick@lassul.us; peers find this instance via the _parley._tcp.lassul.us
  # SRV record (configs/dns/lassul.us.zone).
  lass.parley = {
    enable = true;
    settings = {
      PARLEY_DOMAIN = "lassul.us";
      PARLEY_ENDPOINT = "https://${domain}";
    };
    users.lassulus.role = "admin";
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/".proxyPass = "http://127.0.0.1:${toString config.lass.servicePorts.parley}";
  };

  # IRC over TLS (parleyd advertises 6697 by default)
  services.nginx.streamConfig = ''
    server {
      listen ${toString config.lass.servicePorts.parley-ircs} ssl;
      listen [::]:${toString config.lass.servicePorts.parley-ircs} ssl;
      ssl_certificate /var/lib/acme/${domain}/fullchain.pem;
      ssl_certificate_key /var/lib/acme/${domain}/key.pem;
      proxy_pass 127.0.0.1:${toString config.lass.servicePorts.parley-irc};
    }
  '';
  networking.firewall.allowedTCPPorts = [ config.lass.servicePorts.parley-ircs ];
}
