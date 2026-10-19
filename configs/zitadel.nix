let
  domain = "id.lassul.us";
  port = 1411;
in
{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zitadel;
  vars = config.clan.core.vars.generators.zitadel.files;
  yaml = pkgs.formats.yaml { };
  configFile = yaml.generate "config.yaml" cfg.settings;
  args = lib.cli.toCommandLineShellGNU { } {
    config = [ configFile ];
    steps = [
      (yaml.generate "steps.yaml" cfg.steps)
      vars."steps.yaml".path
    ];
    masterkeyFile = cfg.masterKeyFile;
    inherit (cfg) tlsMode;
  };
  idpCredentials = name: url: {
    prompts.client_id = {
      description = ''
        ${name} login on ${domain}: client id of an OAuth app (${url})
        with the callback URL
          https://${domain}/ui/login/login/externalidp/callback
        Leave empty to not offer ${name} logins.
      '';
      persist = true;
    };
    prompts.client_secret = {
      description = "${name} login on ${domain}: client secret of that OAuth app";
      type = "hidden";
      persist = true;
    };
  };
in
{
  # Zitadel: identity provider for lassul.us services (OIDC). Anyone can
  # register; users sign in with a passkey or an external login (GitHub,
  # Google, their own OpenID provider via byoidc) linked to their account. The
  # login policy, these logins and the services' projects and OIDC apps come from
  # lass.zitadel (modules/zitadel); the zitadel-reconcile service applies
  # them. Further IdPs and the grants of "managed" projects are done in the
  # console at https://id.lassul.us/ui/console.
  #
  # Example projects for services on other hosts, once they speak OIDC (the
  # client secret ends up in /var/lib/zitadel-apps/<project>-<app>.env here):
  #   lass.zitadel.projects.assist = {
  #     access = "declarative";
  #     users = [ "lass@lassul.us" ];
  #     apps.web.redirectUris = [ "https://assist.lassul.us/<callback>" ];
  #   };
  #   lass.zitadel.projects.flix = {
  #     access = "managed";
  #     # jellyfin-plugin-sso with a provider named id.lassul.us
  #     apps.jellyfin.redirectUris = [ "https://flix.lassul.us/sso/OID/redirect/id.lassul.us" ];
  #   };

  clan.core.vars.generators.zitadel = {
    files."masterkey".owner = "zitadel";
    # initial password of the admin user lass, changed at first login
    files."admin-password".deploy = false;
    files."steps.yaml".owner = "zitadel";
    runtimeInputs = [
      pkgs.jq
      pkgs.openssl
      pkgs.pwgen
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/masterkey"
      pwgen -s -c -n -y 32 1 | tr -d '\n' > "$out/admin-password"
      jq -n --rawfile pw "$out/admin-password" \
        '{FirstInstance: {Org: {Human: {Password: $pw}}}}' > "$out/steps.yaml"
    '';
  };

  services.zitadel = {
    enable = true;
    package = self.packages.${pkgs.stdenv.hostPlatform.system}.zitadel;
    masterKeyFile = vars."masterkey".path;
    settings = {
      # daily usage report to zitadel.com, on by default
      ServicePing.Enabled = false;
      # a new instance would otherwise send logins to the separate Login V2 app, which isn't deployed
      DefaultInstance.Features.LoginV2.Required = false;
      Port = port;
      ExternalDomain = domain;
      ExternalPort = 443;
      ExternalSecure = true;
      Machine.Identification = {
        PrivateIp.Enabled = false;
        Hostname.Enabled = true;
        Webhook.Enabled = false;
      };
      Database.postgres = {
        Host = "/run/postgresql";
        Port = 5432;
        Database = "zitadel";
        User.Username = "zitadel";
        Admin.Username = "zitadel";
        Admin.ExistingDatabase = "zitadel";
      };
    };
    steps.FirstInstance = {
      InstanceName = "lassul.us";
      Org = {
        Name = "lassul.us";
        Human = {
          UserName = "lass";
          FirstName = "lass";
          LastName = "lassulus";
          Email = {
            Address = "lass@lassul.us";
            Verified = true;
          };
          PasswordChangeRequired = true;
        };
      };
    };
  };

  lass.zitadel.loginPolicy = {
    allowRegister = true;
    allowExternalIdp = true;
    allowUsernamePassword = true;
    passwordlessType = "PASSWORDLESS_TYPE_ALLOWED";
  };
  # Verification codes and password resets. Zitadel asks every user whose
  # address is unverified (registration, byoidc) to verify it before the
  # login finishes. Sent as the send-only account id@lassul.us of the
  # mailserver here (configs/mailserver.nix), which DKIM-signs it.
  lass.zitadel.smtp = {
    senderAddress = "id@lassul.us";
    senderName = "lassul.us ID";
    host = "mail.lassul.us:465";
    tls = true;
    user = "id@lassul.us";
    passwordFile = config.clan.core.vars.generators.mailserver-id.files."password".path;
  };
  lass.zitadel.idps = {
    GitHub = {
      type = "github";
      clientIdFile = config.clan.core.vars.generators.zitadel-github.files.client_id.path;
      clientSecretFile = config.clan.core.vars.generators.zitadel-github.files.client_secret.path;
      scopes = [
        "read:user"
        "user:email"
      ];
    };
    Google = {
      type = "google";
      clientIdFile = config.clan.core.vars.generators.zitadel-google.files.client_id.path;
      clientSecretFile = config.clan.core.vars.generators.zitadel-google.files.client_secret.path;
      scopes = [
        "openid"
        "profile"
        "email"
      ];
    };
    # byoidc (configs/byoidc.nix): sign in with any OpenID provider. Anyone
    # can run one that claims any email address, so these accounts are never
    # linked to existing ones.
    byoidc = {
      type = "oidc";
      name = "Your own provider";
      issuer = "https://byoidc.lassul.us";
      clientId = "zitadel";
      clientSecretFile = config.clan.core.vars.generators.byoidc.files."client-secret".path;
      providerOptions = {
        isLinkingAllowed = false;
        isCreationAllowed = true;
        isAutoCreation = true;
        isAutoUpdate = true;
      };
    };
  };
  clan.core.vars.generators.zitadel-github =
    idpCredentials "GitHub" "https://github.com/settings/applications/new";
  clan.core.vars.generators.zitadel-google =
    idpCredentials "Google" "https://console.cloud.google.com/apis/credentials";

  # The database and its owner come from ensureDatabases/ensureUsers, so the
  # zitadel role needs no CREATEROLE/CREATEDB. `zitadel init zitadel` creates
  # only the schemas inside it; start-from-setup then skips the role and
  # database creation that start-from-init would attempt.
  systemd.services.zitadel = {
    after = [ "postgresql.target" ];
    requires = [ "postgresql.target" ];
    serviceConfig = {
      ExecStartPre = "${lib.getExe' cfg.package "zitadel"} init zitadel --config ${configFile}";
      ExecStart = lib.mkForce "${lib.getExe' cfg.package "zitadel"} start-from-setup ${args}";
    };
  };

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "zitadel" ];
    ensureUsers = [
      {
        name = "zitadel";
        ensureDBOwnership = true;
      }
    ];
  };

  # users, passkeys, IdP links, OIDC apps; its secrets are encrypted with the
  # masterkey from clan vars
  lass.backup.state.zitadel.preBackup = ''
    mkdir -p /var/backup/postgresql
    ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
      zitadel | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/zitadel.sql.gz
  '';

  # Zitadel serves the console, OIDC and its gRPC APIs on one port over h2c.
  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/".extraConfig = ''
      grpc_pass grpc://127.0.0.1:${toString port};
      grpc_set_header Host $host;
    '';
  };
}
