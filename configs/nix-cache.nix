{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # TODO: create this bucket (public) + an application key for it in B2
  bucket = "lassulus-nix-cache";
  region = "eu-central-003";
  endpoint = "s3.${region}.backblazeb2.com";

  vars = config.clan.core.vars.generators;
in
{
  # "127.0.0.1:5751" -> "5751"
  lass.ports.${lib.last (lib.splitString ":" config.services.niks3.httpAddr)} = "niks3";

  imports = [ self.inputs.niks3.nixosModules.niks3 ];

  # B2 credentials (prompted), the niks3 API token (generated).
  clan.core.vars.generators.niks3 = {
    prompts.b2_key_id = {
      description = "Backblaze B2 keyID with access to the ${bucket} bucket";
      type = "line";
    };
    prompts.b2_application_key = {
      description = "Backblaze B2 applicationKey for that keyID";
      type = "hidden";
    };
    files."s3-access-key".owner = "niks3";
    files."s3-secret-key".owner = "niks3";
    files."api-token".owner = "niks3";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      tr -d '\n' < "$prompts/b2_key_id" > "$out/s3-access-key"
      tr -d '\n' < "$prompts/b2_application_key" > "$out/s3-secret-key"
      openssl rand -hex 32 | tr -d '\n' > "$out/api-token"
    '';
  };

  # Public half is read by configs/default.nix from the vars dir.
  clan.core.vars.generators.nix-cache-signing = {
    files."key.sec".owner = "niks3";
    files."key.pub".secret = false;
    runtimeInputs = [ pkgs.nix ];
    script = ''
      nix --extra-experimental-features nix-command key generate-secret \
        --key-name cache.lassul.us-1 > "$out/key.sec"
      nix --extra-experimental-features nix-command key convert-secret-to-public \
        < "$out/key.sec" > "$out/key.pub"
    '';
  };

  services.niks3 = {
    enable = true;
    s3 = {
      inherit endpoint bucket region;
      accessKeyFile = vars.niks3.files."s3-access-key".path;
      secretKeyFile = vars.niks3.files."s3-secret-key".path;
    };
    apiTokenFile = vars.niks3.files."api-token".path;
    signKeyFiles = [ vars.nix-cache-signing.files."key.sec".path ];
    cacheUrl = "https://cache.lassul.us";
    # Behind cache.nixos.org (40): nix asks upstream first, so B2 only sees
    # lookups for our own paths. At niks3's default 30 every closure path of
    # a CI build would hit B2 first, and B2 throttles that many misses with
    # 503s.
    priority = 50;
    # CI (.github/workflows/ci.yml) pushes with the job's GitHub OIDC token,
    # so does droid-nix's CI. Fork PRs don't get one. A token matching any of
    # the repositories is accepted.
    oidc.providers.github = {
      issuer = "https://token.actions.githubusercontent.com";
      audience = "https://niks3.lassul.us";
      boundClaims.repository = [
        "lassulus/superconfig"
        "lassulus/droid-nix"
      ];
    };
    nginx = {
      enable = true;
      domain = "niks3.lassul.us";
    };
  };

  # Reads straight from the public bucket. niks3 uploads the metadata
  # zstd-compressed with Content-Encoding: zstd; set it here so nix decodes
  # it whether or not the bucket hands the header back. Same rules as
  # clan-infra's Fastly config (modules/terranix/cache-new.nix): narinfo, .ls,
  # realisations/ and log/. NARs (nar/*.nar.zst) are plain objects, nix
  # decodes them via the narinfo's Compression field.
  # `resolve`: looked up at runtime via resolved's stub, so an unresolvable
  # B2 at startup doesn't keep nginx (and every other vhost) from starting.
  # `keepalive` + HTTP/1.1 below: reuse TLS connections to B2. Without them
  # nginx speaks HTTP/1.0 with a new handshake per request, and at hundreds
  # of requests per second B2 closes connections mid-response.
  # `max_fails=0`: B2 closes idle keepalive connections now and then. With the
  # default max_fails=1 one such close marks that B2 address down for 10s;
  # once all of them are, every request gets "no live upstreams" and a 502.
  # A GET/HEAD on a closed reused connection is retried
  # (default `proxy_next_upstream error timeout`) without using up a try, on
  # the next address, or on the same one if it resolves to only one.
  services.nginx.appendHttpConfig = ''
    upstream cache_lassul_us_b2 {
      zone cache_lassul_us_b2 64k;
      resolver 127.0.0.53 ipv6=off;
      server ${endpoint}:443 resolve max_fails=0;
      keepalive 64;
      keepalive_requests 10000;
      keepalive_timeout 60s;
    }
    map $uri $cache_lassul_us_encoding {
      default "";
      ~\.(narinfo|ls)$ zstd;
      ~^/realisations/ zstd;
      ~^/log/ zstd;
    }
  '';
  services.nginx.virtualHosts."cache.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/".extraConfig = ''
      proxy_pass https://cache_lassul_us_b2/${bucket}/;
      proxy_set_header Host ${endpoint};
      proxy_ssl_server_name on;
      proxy_ssl_name ${endpoint};
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      # cache keys never have a query string; don't forward one to S3
      set $args "";
      # S3 answers 403 for keys missing from a bucket it won't list
      proxy_intercept_errors on;
      error_page 403 =404 @notfound;

      gzip off;
      proxy_hide_header Content-Encoding;
      # only sent on 2xx/3xx, and not at all when the map yields ""
      add_header Content-Encoding $cache_lassul_us_encoding;
    '';
    locations."@notfound".return = "404";
  };
}
