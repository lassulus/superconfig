# Login via id.lassul.us (Zitadel project hass, configs/hass/proxy.nix) with
# the auth_oidc custom component. The username/password login stays.
{ config, pkgs, ... }:
{
  # Loaded from /config/packages like configs/hass/monitoring.nix.
  # automatic_user_linking: the first login reuses the HA user whose username
  # equals the preferred_username claim; only users granted the project can
  # log in at all.
  virtualisation.oci-containers.containers.homeassistant = {
    volumes = [
      "${pkgs.home-assistant-custom-components.auth_oidc}/custom_components/auth_oidc:/config/custom_components/auth_oidc:ro"
      "${pkgs.writeText "auth_oidc.yaml" ''
        auth_oidc:
          client_id: !env_var HASS_OIDC_CLIENT_ID
          discovery_url: https://id.lassul.us/.well-known/openid-configuration
          display_name: lassul.us ID
          features:
            automatic_user_linking: true
            include_groups_scope: false
      ''}:/config/packages/auth_oidc.yaml:ro"
    ];
    environmentFiles = [ config.clan.core.vars.generators.hass-oidc.files.env.path ];
  };

  clan.core.vars.generators.hass-oidc = {
    files.env = { };
    prompts.client-id.description = "Client id of the Zitadel app hass/web (CLIENT_ID in /var/lib/zitadel-apps/hass-web.env on neoprism)";
    script = ''
      printf 'HASS_OIDC_CLIENT_ID=%s\n' "$(cat "$prompts"/client-id)" > "$out/env"
    '';
  };
}
