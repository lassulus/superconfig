# Login via id.lassul.us (Zitadel project flix, configs/services/flix/proxy.nix)
# with the SSO plugin, next to the normal Jellyfin passwords.
{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  plugin = self.packages.${pkgs.stdenv.hostPlatform.system}.jellyfin-plugin-sso;
  pluginsDir = "${config.services.jellyfin.dataDir}/plugins";
  provider = "id.lassul.us";
  settings = pkgs.writeText "jellyfin-sso.json" (
    builtins.toJSON {
      inherit provider;
      pluginConfig = "${pluginsDir}/configurations/SSO-Auth.xml";
      brandingConfig = "${config.services.jellyfin.configDir}/branding.xml";
      clientIdFile = config.clan.core.vars.generators.flix-oidc.files.client-id.path;
      # Public client with PKCE, so no OidSecret. Permissions stay as they
      # are in Jellyfin (no role mapping); the first login of an unlinked
      # identity takes over the account whose username equals the
      # preferred_username claim, else creates a new one.
      oid = {
        OidEndpoint = "https://${provider}";
        EnableAuthorization = false;
        # Jellyfin sees plain http from the proxy on neoprism.
        SchemeOverride = "https";
      };
      loginDisclaimer = ''
        <form action="https://flix.lassul.us/sso/OID/start/${provider}">
          <button class="raised block emby-button button-submit">Sign in with ${provider}</button>
        </form>
      '';
    }
  );
in
{
  assertions = [
    {
      assertion = lib.versions.major config.services.jellyfin.package.version == "12";
      message = "jellyfin-plugin-sso ${plugin.version} is built for Jellyfin 12, not ${config.services.jellyfin.package.version}";
    }
  ];

  clan.core.vars.generators.flix-oidc = {
    files.client-id.owner = "jellyfin";
    prompts.client-id.description = "Client id of the Zitadel app flix/jellyfin (CLIENT_ID in /var/lib/zitadel-apps/flix-jellyfin.env on neoprism)";
    script = ''
      cat "$prompts"/client-id > "$out"/client-id
    '';
  };

  # Copied rather than linked: Jellyfin writes meta.json in the plugin dir.
  systemd.services.jellyfin.preStart = ''
    mkdir -p ${pluginsDir}
    rm -rf ${pluginsDir}/SSO-Auth_*
    cp -r --no-preserve=mode ${plugin} ${pluginsDir}/${plugin.pluginDir}
    ${pkgs.python3.interpreter} ${./jellyfin-sso-config.py} ${settings}
  '';
}
