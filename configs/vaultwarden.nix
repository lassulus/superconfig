{
  config,
  options,
  pkgs,
  ...
}:
{
  clan.core.vars.generators.vaultwarden = {
    files.vaultwarden_admin_token.deploy = false;
    files."vaultwarden.env" = { };
    runtimeInputs = [
      pkgs.pwgen
      pkgs.libargon2
    ];
    script = ''
      pwgen 20 1 | tr -d '\n' > $out/vaultwarden_admin_token
      cat $out/vaultwarden_admin_token | argon2 "$(pwgen 20 1 | tr -d '\n')" -e > vaultwarden_token_hashed
      cat > "$out/vaultwarden.env" << EOF
      ADMIN_TOKEN='$(cat vaultwarden_token_hashed)'
      EOF
    '';
  };
  services.vaultwarden = {
    enable = true;
    environmentFile = config.clan.core.vars.generators.vaultwarden.files."vaultwarden.env".path;
    config = options.services.vaultwarden.config.default // {
      SIGNUPS_ALLOWED = false;
      DOMAIN = "https://vault.lassul.us";
      WEBSOCKET_ENABLED = true;
    };
  };

  # StateDirectory before stateVersion 24.11
  lass.backup.state.vaultwarden.folders = [ "/var/lib/bitwarden_rs" ];

  services.nginx.virtualHosts."vault.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/".proxyPass =
      "http://localhost:${toString config.services.vaultwarden.config.ROCKET_PORT}";
  };
}
