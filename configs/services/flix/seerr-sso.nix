# Login to Seerr (flox.lassul.us) via id.lassul.us (Zitadel project flix,
# configs/services/flix/proxy.nix), next to the Jellyfin and local logins.
#
# Seerr keeps its settings in a mutable settings.json, so the provider is
# merged into it before every start; everything else in the file stays as
# set in the web ui.
#
# Users are matched by the Zitadel user id (sub) in the table
# linked_accounts. Existing users link once: log in as before, then
# Profile > Settings > Linked Accounts > id.lassul.us. newUserLogin is off:
# an unlinked login is refused instead of creating a second account.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.seerr;
  vars = config.clan.core.vars.generators.flox-oidc.files;
  settingsFile = "${cfg.configDir}/settings.json";
  provider = {
    # stored with every linked account; never change it
    slug = "id-lassul-us";
    name = "id.lassul.us";
    issuerUrl = "https://id.lassul.us";
    scopes = "openid profile email";
    newUserLogin = false;
  };
  merge = pkgs.writeText "seerr-oidc.jq" ''
    .main.oidcLogin = true
    | .main.localLogin = true
    | .main.mediaServerLogin = true
    | .oidc.providers = [.oidc.providers[]? | select(.slug != "${provider.slug}")]
        + [${builtins.toJSON provider} + {
          clientId: ($id | rtrimstr("\n")),
          clientSecret: ($secret | rtrimstr("\n"))
        }]
  '';
in
{
  # OIDC login from the open upstream PR
  # https://github.com/seerr-team/seerr/pull/2715 (branch
  # michaelhthomas:feat/oidc-login-basic, based on develop after 3.5.2).
  # Back to the nixpkgs package once a Seerr release has OIDC; its migration
  # AddLinkedAccounts1742858484395 adds the table linked_accounts.
  services.seerr.package = pkgs.seerr.overrideAttrs (
    finalAttrs: prev: {
      version = "3.5.2-unstable-2026-11-15";
      src = pkgs.fetchFromGitHub {
        owner = "seerr-team";
        repo = "seerr";
        rev = "0aa680565233bcfd67bfa4bce5b12f9f89f134da";
        hash = "sha256-VZN6C02nVuF6tunTLQhDYF+nYS99jZlP/uywXRdkwZ4=";
      };
      pnpmDeps = pkgs.fetchPnpmDeps {
        inherit (finalAttrs) pname version src;
        pnpm = pkgs.pnpm_10.override { nodejs-slim = pkgs.nodejs-slim_22; };
        fetcherVersion = 3;
        hash = "sha256-gqjz0DM0VYdFKTkoKPG9fjAwZlKeQZS1GB4wwUcwZ9M=";
      };
      # develop's package.json says 0.1.0; Seerr then shows develop-<commitTag>
      postInstall = prev.postInstall + ''
        echo '{"commitTag":"${finalAttrs.src.rev}"}' > $out/share/committag.json
      '';
    }
  );

  clan.core.vars.generators.flox-oidc = {
    # root-owned; systemd hands them to the DynamicUser via LoadCredential
    files.client-id = { };
    files.client-secret = { };
    prompts.client-id.description = "Client id of the Zitadel app flix/seerr (CLIENT_ID in /var/lib/zitadel-apps/flix-seerr.env on neoprism)";
    prompts.client-secret = {
      description = "Client secret of the Zitadel app flix/seerr (CLIENT_SECRET in the same file)";
      type = "hidden";
    };
    script = ''
      cat "$prompts"/client-id > "$out"/client-id
      cat "$prompts"/client-secret > "$out"/client-secret
    '';
  };

  systemd.services.seerr = {
    serviceConfig.LoadCredential = [
      "oidc-client-id:${vars.client-id.path}"
      "oidc-client-secret:${vars.client-secret.path}"
    ];
    # settings.json only exists after the first start; from the next start
    # on the provider is applied.
    preStart = ''
      if [ -f ${settingsFile} ]; then
        ${lib.getExe pkgs.jq} \
          --rawfile id "$CREDENTIALS_DIRECTORY"/oidc-client-id \
          --rawfile secret "$CREDENTIALS_DIRECTORY"/oidc-client-secret \
          -f ${merge} ${settingsFile} > ${settingsFile}.tmp
        mv ${settingsFile}.tmp ${settingsFile}
      fi
    '';
  };
}
