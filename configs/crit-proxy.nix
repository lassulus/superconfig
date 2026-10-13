{ config, ... }:
let
  cert = "wildcard.review.lassul.us";
in
{
  # Public door to crit reviews on coaxmetal (configs/crit.nix): every review
  # gets a random https://<id>.review.lassul.us, routed to its daemon by the
  # nginx on coaxmetal:7720.
  #
  # Wildcard cert only: a per-name cert would publish every id in the
  # Certificate Transparency logs. DNS-01 against our own knot, see the
  # _acme-challenge.review.lassul.us zone in configs/dns/knot.nix.
  security.acme.certs.${cert} = {
    domain = "*.review.lassul.us";
    dnsProvider = "rfc2136";
    environmentFile = config.clan.core.vars.generators.knot-acme-review.files."lego.env".path;
    group = config.services.nginx.group;
  };

  services.nginx.virtualHosts.crit-review = {
    serverName = ''"~^[a-z0-9]{10}\.review\.lassul\.us$"'';
    useACMEHost = cert;
    forceSSL = true;
    # crit streams review updates over SSE
    locations."/" = {
      recommendedProxySettings = true;
      proxyPass = "http://coaxmetal.r:7720";
      extraConfig = ''
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_connect_timeout 5s;
      '';
    };
  };
}
