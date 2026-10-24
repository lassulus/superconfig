# Grafana of this server at https://grafana.lassul.us (proxied by neoprism,
# configs/monitoring/grafana-proxy.nix), login only via id.lassul.us.
{ config, lib, ... }:
{
  services.grafana.settings = {
    server = {
      domain = "grafana.lassul.us";
      root_url = "https://grafana.lassul.us/";
    };
    security.cookie_secure = true;
    # The admin user stays for the API (basic auth) and `grafana cli`.
    auth = {
      disable_login_form = true;
      oauth_allow_insecure_email_lookup = false;
    };
    "auth.anonymous".enabled = lib.mkForce false;
    # Users are matched by the token's sub only: generic_oauth always takes
    # the auth id from sub (Grafana 13 has no id_attribute_path), and email
    # lookup is off above. client_id comes from the grafana-oidc var
    # (GF_AUTH_GENERIC_OAUTH_CLIENT_ID).
    "auth.generic_oauth" = {
      enabled = true;
      name = "lassul.us ID";
      use_pkce = true;
      auth_style = "InParams";
      scopes = "openid profile email";
      auth_url = "https://id.lassul.us/oauth/v2/authorize";
      token_url = "https://id.lassul.us/oauth/v2/token";
      api_url = "https://id.lassul.us/oidc/v1/userinfo";
      login_attribute_path = "preferred_username";
      email_attribute_path = "email";
      allow_sign_up = true;
      # Only the users listed on the Zitadel project get here. Not the bare
      # literal 'GrafanaAdmin': go-ini strips quotes surrounding a whole
      # value, leaving the identifier GrafanaAdmin (null -> Viewer). Every
      # OIDC userinfo has a sub, so this always yields GrafanaAdmin.
      role_attribute_path = "sub && 'GrafanaAdmin'";
      allow_assign_grafana_admin = true;
    };
  };

  # "-": Grafana also starts before the var is set.
  systemd.services.grafana.serviceConfig.EnvironmentFile =
    "-${config.clan.core.vars.generators.grafana-oidc.files.env.path}";

  clan.core.vars.generators.grafana-oidc = {
    files.env = { };
    prompts.client-id.description = "Client id of the Zitadel app grafana/web (CLIENT_ID in /var/lib/zitadel-apps/grafana-web.env on neoprism)";
    script = ''
      printf 'GF_AUTH_GENERIC_OAUTH_CLIENT_ID=%s\n' "$(cat "$prompts"/client-id)" > "$out/env"
    '';
  };
}
