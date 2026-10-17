let
  domain = "id.lassul.us";
  port = 1411;
in
{
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
in
{
  # Zitadel: identity provider for lassul.us services (OIDC). Anyone can
  # register; users sign in with a passkey or an external login (GitHub,
  # Google, other OIDC) linked to their account. The external IdPs and OIDC
  # apps are managed in the console at https://id.lassul.us/ui/console.

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
    masterKeyFile = vars."masterkey".path;
    settings = {
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
      # Applied once, when the first instance is created.
      DefaultInstance.LoginPolicy = {
        AllowRegister = true;
        AllowExternalIDP = true;
        AllowUsernamePassword = true;
        PasswordlessType = 1; # passkeys allowed
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
