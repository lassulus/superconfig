{
  config,
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
  imports = [ self.inputs.niks3.nixosModules.niks3 ];

  # B2 credentials (prompted), the niks3 API token (generated; one copy per
  # service user that reads it).
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
    files."api-token-grpc".owner = "nix-grpc-daemon";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      tr -d '\n' < "$prompts/b2_key_id" > "$out/s3-access-key"
      tr -d '\n' < "$prompts/b2_application_key" > "$out/s3-secret-key"
      openssl rand -hex 32 | tr -d '\n' > "$out/api-token"
      cp "$out/api-token" "$out/api-token-grpc"
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
  services.nginx.appendHttpConfig = ''
    upstream cache_lassul_us_b2 {
      zone cache_lassul_us_b2 64k;
      resolver 127.0.0.53 ipv6=off;
      server ${endpoint}:443 resolve;
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
