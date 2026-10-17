{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.lass.zitadel;
  zitadel = config.services.zitadel;
  appsDir = "/var/lib/zitadel-apps";
  # Written by zitadel's setup when it creates the first instance.
  patFile = "/var/lib/zitadel/reconcile.pat";

  reconcileConfig = pkgs.writeText "zitadel-reconcile.json" (
    builtins.toJSON {
      url = "http://127.0.0.1:${toString zitadel.settings.Port}";
      domain = zitadel.settings.ExternalDomain;
      stateDir = appsDir;
      inherit patFile;
      inherit (cfg) loginPolicy idps;
      projects = lib.mapAttrs (_: project: {
        inherit (project) access users;
        apps = lib.mapAttrs (_: app: {
          inherit (app) redirectUris envFile;
          authMethodType = "OIDC_AUTH_METHOD_TYPE_${lib.toUpper app.authMethod}";
        }) project.apps;
      }) cfg.projects;
    }
  );
in
{
  options.lass.zitadel = {
    loginPolicy = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        allowRegister = true;
      };
      description = ''
        Fields of the instance's default login policy, as in Zitadel's admin
        API (PUT /admin/v1/policies/login). Unlisted fields keep their value.
      '';
    };

    idps = lib.mkOption {
      default = { };
      description = ''
        External identity providers, added to the login policy. An IdP whose
        client id or secret is empty is skipped.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              type = lib.mkOption {
                type = lib.types.enum [
                  "github"
                  "google"
                  "oidc"
                ];
              };
              name = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Display name on the login page; the IdP is found by it.";
              };
              issuer = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Issuer of a generic OIDC IdP (type = \"oidc\").";
              };
              clientId = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              clientIdFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              clientSecretFile = lib.mkOption { type = lib.types.str; };
              scopes = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [
                  "openid"
                  "profile"
                  "email"
                ];
              };
              providerOptions = lib.mkOption {
                type = lib.types.attrsOf lib.types.bool;
                default = {
                  isLinkingAllowed = true;
                  isCreationAllowed = true;
                  isAutoUpdate = true;
                };
                description = ''
                  Options of the IdP, as in Zitadel's admin API
                  (zitadel.idp.v1.Options).
                '';
              };
            };
          }
        )
      );
    };

    projects = lib.mkOption {
      default = { };
      description = ''
        Zitadel projects, one per service, in the default organization.
        Projects and apps removed from here are left in Zitadel.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          let
            project = name;
          in
          {
            options = {
              access = lib.mkOption {
                type = lib.types.enum [
                  "public"
                  "declarative"
                  "managed"
                ];
                description = ''
                  Who may log in to the project's apps:
                  - public: every user of the instance.
                  - declarative: the users listed in `users`. All other user
                    grants of the project are removed.
                  - managed: users with a user grant on the project, given by
                    an admin in the console.
                '';
              };
              users = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Verified email addresses of the users that get a user
                  grant on the project (access = "declarative"). Not login
                  names: anyone can register a free one that looks like
                  someone's address. Users who have not registered or
                  verified their address yet are skipped until the next run.
                '';
              };
              apps = lib.mkOption {
                default = { };
                description = "OIDC web apps of the project.";
                type = lib.types.attrsOf (
                  lib.types.submodule (
                    { name, ... }:
                    {
                      options = {
                        redirectUris = lib.mkOption { type = lib.types.listOf lib.types.str; };
                        authMethod = lib.mkOption {
                          type = lib.types.enum [
                            "basic"
                            "post"
                          ];
                          default = "basic";
                          description = "How the app sends its client secret to the token endpoint.";
                        };
                        envFile = {
                          path = lib.mkOption {
                            type = lib.types.str;
                            default = "${appsDir}/${project}-${name}.env";
                            description = "Env file with the app's client id and secret.";
                          };
                          owner = lib.mkOption {
                            type = lib.types.str;
                            default = "root";
                          };
                          clientIdVariable = lib.mkOption {
                            type = lib.types.str;
                            default = "CLIENT_ID";
                          };
                          clientSecretVariable = lib.mkOption {
                            type = lib.types.str;
                            default = "CLIENT_SECRET";
                          };
                        };
                      };
                    }
                  )
                );
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf zitadel.enable {
    assertions =
      lib.mapAttrsToList (name: project: {
        assertion = project.users == [ ] || project.access == "declarative";
        message = "lass.zitadel.projects.${name}.users needs access = \"declarative\"";
      }) cfg.projects
      ++ lib.mapAttrsToList (name: idp: {
        assertion = (idp.clientId == null) != (idp.clientIdFile == null);
        message = "lass.zitadel.idps.${name} needs exactly one of clientId and clientIdFile";
      }) cfg.idps
      ++ lib.mapAttrsToList (name: idp: {
        assertion = (idp.type == "oidc") == (idp.issuer != null);
        message = "lass.zitadel.idps.${name}.issuer is needed for, and only for, type = \"oidc\"";
      }) cfg.idps;

    services.zitadel.steps.FirstInstance = {
      PatPath = patFile;
      Org.Machine.Machine = {
        Username = "reconcile";
        Name = "zitadel-reconcile";
      };
      # Zitadel's default for tokens without expiry; an empty Pat section
      # creates no token.
      Org.Machine.Pat.ExpirationDate = "9999-01-01T00:00:00Z";
    };
    systemd.services.zitadel.serviceConfig = {
      StateDirectory = "zitadel";
      StateDirectoryMode = "0700";
    };

    systemd.services.zitadel-reconcile = {
      description = "Apply lass.zitadel to Zitadel";
      wantedBy = [ "multi-user.target" ];
      wants = [ "zitadel.service" ];
      after = [ "zitadel.service" ];
      environment.PYTHONUNBUFFERED = "1";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${
          pkgs.writers.writePython3 "zitadel-reconcile" { } ./reconcile.py
        } ${reconcileConfig}";
        StateDirectory = "zitadel-apps";
        StateDirectoryMode = "0711";
        UMask = "0077";
      };
    };
  };
}
