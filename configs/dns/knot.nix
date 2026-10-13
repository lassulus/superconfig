{
  config,
  lib,
  pkgs,
  ...
}:
let
  ip4 = "95.217.192.59";
  ip6 = "2a01:4f9:4a:4f1a::2";
  # Delegated from lassul.us (NS ns1 only, the Hetzner secondaries never see
  # it) so lego can do DNS-01 for *.review.lassul.us (configs/crit-proxy.nix)
  # with RFC2136 updates, without touching the signed main zone.
  acmeReviewZone = pkgs.writeText "_acme-challenge.review.lassul.us.zone" ''
    @ 3600 IN SOA ns1.lassul.us. acme.lassul.us. 1 7200 3600 86400 60
    @ 3600 IN NS ns1.lassul.us.
  '';
  # dyndns = domain:
  #   pkgs.writeText "${domain}.zone" ''
  #     @ 3600 IN SOA ${domain}. ns1.lassul.us. 2023101213 7200 3600 86400 3600

  #     $TTL 300

in
#     @ IN NS ns1.lassul.us.
#   '';
{
  # TSIG key for the acme-review updates, for knot and for lego
  clan.core.vars.generators.knot-acme-review = {
    files."knot-key.conf".owner = "knot";
    files."lego.env".owner = "acme";
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      secret=$(openssl rand -base64 32)
      printf 'key:\n  - id: acme-review\n    algorithm: hmac-sha256\n    secret: %s\n' "$secret" \
        > "$out/knot-key.conf"
      printf 'RFC2136_NAMESERVER=%s\nRFC2136_TSIG_ALGORITHM=hmac-sha256.\nRFC2136_TSIG_KEY=acme-review\nRFC2136_TSIG_SECRET=%s\n' \
        ${ip4} "$secret" > "$out/lego.env"
    '';
  };

  services.knot = {
    enable = true;
    keyFiles = [
      config.clan.core.vars.generators.knot-acme-review.files."knot-key.conf".path
    ];
    settings = {
      server = {
        listen = [
          "${ip4}@53"
          "${ip6}@53"
        ];
      };

      remote = [
        {
          id = "hetzner_ip4_1";
          address = "213.239.242.238@53";
        }
        {
          id = "hetzner_ip4_2";
          address = "213.133.100.103@53";
        }
        {
          id = "hetzner_ip4_3";
          address = "193.47.99.3@53";
        }
        {
          id = "hetzner_ip6_1";
          address = "2a01:4f8:0:a101::a:1@53";
        }
        {
          id = "hetzner_ip6_2";
          address = "2a01:4f8:0:1::5ddc:2@53";
        }
        {
          id = "hetzner_ip6_3";
          address = "2001:67c:192c::add:a3";
        }
      ];

      # to generate TSIG key
      # for i in host; do keymgr -t $i; done
      acl = [
        {
          id = "hetzner_ip4_1";
          address = "213.239.242.238";
          action = "transfer";
        }
        {
          id = "hetzner_ip4_2";
          address = "213.133.100.103";
          action = "transfer";
        }
        {
          id = "hetzner_ip4_3";
          address = "193.47.99.3";
          action = "transfer";
        }
        {
          id = "hetzner_ip6_1";
          address = "2a01:4f8:0:a101::a:1";
          action = "transfer";
        }
        {
          id = "hetzner_ip6_2";
          address = "2a01:4f8:0:1::5ddc:2";
          action = "transfer";
        }
        {
          id = "hetzner_ip6_3";
          address = "2001:67c:192c::add:a3";
          action = "transfer";
        }
        {
          id = "acme_review";
          key = "acme-review";
          address = [
            ip4
            ip6
          ];
          action = "update";
          update-type = [ "TXT" ];
        }
      ];

      mod-rrl = [
        {
          id = "default";
          rate-limit = 200;
          slip = 2;
        }
      ];

      policy = [
        {
          id = "rsa2k";
          algorithm = "RSASHA256";
          ksk-size = 4096;
          zsk-size = 2048;
          nsec3 = true;
        }
      ];

      template = [
        {
          id = "default";
          semantic-checks = "on";
          global-module = "mod-rrl/default";
        }
        {
          id = "master";
          semantic-checks = "on";
          notify = [
            "hetzner_ip4_1"
            "hetzner_ip4_2"
            "hetzner_ip4_3"
            "hetzner_ip6_1"
            "hetzner_ip6_2"
            "hetzner_ip6_3"
          ];
          acl = [
            "hetzner_ip4_1"
            "hetzner_ip4_2"
            "hetzner_ip4_3"
            "hetzner_ip6_1"
            "hetzner_ip6_2"
            "hetzner_ip6_3"
          ];
          zonefile-sync = "-1";
          zonefile-load = "difference-no-serial";
          serial-policy = "dateserial";
          journal-content = "all";
        }
      ];

      zone = [
        {
          domain = "lassul.us";
          file = "${./lassul.us.zone}";
          notify = [
            "hetzner_ip4_1"
            "hetzner_ip4_2"
            "hetzner_ip4_3"
            "hetzner_ip6_1"
            "hetzner_ip6_2"
            "hetzner_ip6_3"
          ];
          acl = [
            "hetzner_ip4_1"
            "hetzner_ip4_2"
            "hetzner_ip4_3"
            "hetzner_ip6_1"
            "hetzner_ip6_2"
            "hetzner_ip6_3"
          ];
          dnssec-signing = true;
          dnssec-policy = "rsa2k";
          # Disable zone file syncing since the zone file is in the read-only Nix store
          # This prevents "flush event failed" errors when knot tries to write DNSSEC updates
          zonefile-sync = "-1";
          # Load zone changes from journal instead of rewriting the zone file
          # Required when DNSSEC signing is enabled with read-only zone files
          # Use difference-no-serial to auto-increment serial based on serial-policy
          zonefile-load = "difference-no-serial";
          serial-policy = "dateserial";
          journal-content = "all";
        }
        {
          domain = "_acme-challenge.review.lassul.us";
          file = "${acmeReviewZone}";
          acl = [ "acme_review" ];
          zonefile-sync = "-1";
          zonefile-load = "difference-no-serial";
          journal-content = "all";
        }
      ];
    };
  };

  # disable to enable auto key generation
  systemd.services.knot.serviceConfig.SystemCallFilter = lib.mkForce [ ];

  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}
