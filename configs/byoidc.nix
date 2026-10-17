let
  domain = "byoidc.lassul.us";
  port = 8773;
in
{
  config,
  pkgs,
  self,
  ...
}:
{
  # byoidc: OIDC provider that signs users in with their own OpenID provider.
  # Zitadel offers it as the IdP "Your own provider" (configs/zitadel.nix),
  # which uses the client "zitadel" below with the same client secret.
  imports = [ self.inputs.byoidc.nixosModules.byoidc ];

  services.byoidc = {
    enable = true;
    listen = "127.0.0.1:${toString port}";
    publicUrl = "https://${domain}";
    clientName = "byoidc (lassul.us)";
    clientUri = "https://lassul.us";
    trustForwardedFor = true;
    client = {
      id = "zitadel";
      secretFile = config.clan.core.vars.generators.byoidc.files."client-secret".path;
      redirectUris = [ "https://id.lassul.us/ui/login/login/externalidp/callback" ];
    };
  };

  clan.core.vars.generators.byoidc = {
    files."client-secret" = { };
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/client-secret"
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      # byoidc rate-limits on the last X-Forwarded-For entry; set it from the
      # socket, never from a client-supplied header.
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}
