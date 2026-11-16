# Login to audiobookshelf (audible.lassul.us) via id.lassul.us (Zitadel
# project audible, configs/services/flix/proxy.nix), also from the apps.
# audiobookshelf keeps these settings in its database, so they are written
# there before every start; a first login creates the user.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vars = config.clan.core.vars.generators.audible-oidc.files;
  db = "/var/lib/${config.services.audiobookshelf.dataDir}/config/absdatabase.sqlite";
  issuer = "https://id.lassul.us";
  # local stays for the root account, which only exists for the API
  settings = {
    authActiveAuthMethods = [
      "local"
      "openid"
    ];
    authOpenIDIssuerURL = issuer;
    authOpenIDAuthorizationURL = "${issuer}/oauth/v2/authorize";
    authOpenIDTokenURL = "${issuer}/oauth/v2/token";
    authOpenIDUserInfoURL = "${issuer}/oidc/v1/userinfo";
    authOpenIDJwksURL = "${issuer}/oauth/v2/keys";
    authOpenIDLogoutURL = "${issuer}/oidc/v1/end_session";
    authOpenIDTokenSigningAlgorithm = "RS256";
    authOpenIDButtonText = "Login with id.lassul.us";
    # the web ui goes straight to id.lassul.us; /login?autoLaunch=0 for root
    authOpenIDAutoLaunch = true;
    authOpenIDAutoRegister = true;
    # redirect uris under the web ui's base path, as in proxy.nix
    authOpenIDSubfolderForRedirectURLs = "/audiobookshelf";
    authOpenIDMobileRedirectURIs = [ "audiobookshelf://oauth" ];
  };
  sql = pkgs.writeText "audiobookshelf-sso.sql" ''
    UPDATE settings SET value = json_set(json_patch(value, json('${builtins.toJSON settings}')),
      '$.authOpenIDClientID', rtrim(readfile('${vars.client-id.path}'), char(10)),
      '$.authOpenIDClientSecret', rtrim(readfile('${vars.client-secret.path}'), char(10)))
    WHERE key = 'server-settings';
  '';
in
{
  clan.core.vars.generators.audible-oidc = {
    files.client-id.owner = config.services.audiobookshelf.user;
    files.client-secret.owner = config.services.audiobookshelf.user;
    prompts.client-id.description = "Client id of the Zitadel app audible/audiobookshelf (CLIENT_ID in /var/lib/zitadel-apps/audible-audiobookshelf.env on neoprism)";
    prompts.client-secret = {
      description = "Client secret of the Zitadel app audible/audiobookshelf (CLIENT_SECRET in the same file)";
      type = "hidden";
    };
    script = ''
      cat "$prompts"/client-id > "$out"/client-id
      cat "$prompts"/client-secret > "$out"/client-secret
    '';
  };

  # The database only exists after the first start (setup page); from the
  # next start on the settings are applied.
  systemd.services.audiobookshelf.preStart = ''
    if [ -f ${db} ]; then
      ${lib.getExe pkgs.sqlite} ${db} < ${sql}
    fi
  '';
}
