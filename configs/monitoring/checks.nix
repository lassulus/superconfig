# Gatus endpoints, the same on every monitoring server. Gatus itself doesn't
# alert: its results are scraped into VictoriaMetrics (with a vantage label
# naming the server) and vmalert alerts on them (GatusEndpointDown).
let
  inherit (import ./default.nix) alwaysOn;

  certValid = "[CERTIFICATE_EXPIRATION] > 336h"; # 14 days

  https = name: url: {
    inherit name url;
    group = "https";
    conditions = [
      "[STATUS] == 200"
      certValid
    ];
  };

  # The primary and the three Hetzner secondaries (configs/dns/knot.nix).
  soa = name: server: {
    inherit name;
    group = "dns";
    url = server;
    dns = {
      query-name = "lassul.us";
      query-type = "SOA";
    };
    conditions = [ "[DNS_RCODE] == NOERROR" ];
  };

  tls = name: url: {
    inherit name url;
    group = "mail";
    conditions = [
      "[CONNECTED] == true"
      certValid
    ];
  };

  ping = host: {
    name = host;
    group = "retiolum";
    url = "icmp://${host}.r";
    conditions = [ "[CONNECTED] == true" ];
  };
in
{
  endpoints = map (e: { interval = "2m"; } // e) (
    [
      (https "lassul.us" "https://lassul.us/")
      (https "matrix" "https://matrix.lassul.us/_matrix/client/versions")
      (https "pad" "https://pad.lassul.us/")
      (https "id" "https://id.lassul.us/debug/healthz")
      (https "byoidc" "https://byoidc.lassul.us/healthz")
      (https "paint" "https://paint.lassul.us/")
      (https "ntfy" "https://ntfy.lassul.us/v1/health")
      (https "paperless" "https://paperless.lassul.us/accounts/login/")
      (https "cache" "https://cache.lassul.us/nix-cache-info")
      (https "niks3" "https://niks3.lassul.us/health")
      (soa "ns1" "95.217.192.59")
      (soa "ns1.first-ns.de" "213.239.242.238")
      (soa "robotns2.second-ns.de" "213.133.100.103")
      (soa "robotns3.second-ns.com" "193.47.99.3")
      (tls "smtps" "tls://mail.lassul.us:465")
      (tls "imaps" "tls://mail.lassul.us:993")
      {
        name = "federation";
        group = "matrix";
        url = "https://federationtester.matrix.org/api/report?server_name=lassul.us";
        interval = "30m";
        conditions = [
          "[STATUS] == 200"
          "[BODY].FederationOK == true"
        ];
      }
    ]
    ++ map ping alwaysOn
  );
}
