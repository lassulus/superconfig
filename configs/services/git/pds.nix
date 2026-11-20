{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = "pds.lassul.us";
  cfg = config.services.tranquil-pds;
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.tranquil-pds;
  zitadelEnv = config.lass.zitadel.projects.pds.apps.web.envFile.path;

  # Who may log in (the grant on the Zitadel project pds), by the address of
  # their id.lassul.us user. With a handle, pds-reconcile creates the
  # account <handle>.pds.lassul.us, linked to that user: they just sign in
  # with id.lassul.us. A new address gets a Zitadel user with an invite
  # mail. Without one, the account is the owner's own signup on
  # pds.lassul.us. sshKeys: org.tangled.key.sshKey records (pushing to
  # knot.lassul.us), removed again when dropped from here; keys added on
  # tangled.org stay.
  accounts = {
    "lass@lassul.us" = { };
    # agentd's account (configs/services/agentd), forks and PRs on
    # knot.lassul.us
    "slop@lassul.us" = { };
    # slopulus' account: its PRs from its fork (instead of crit reviews),
    # also those of the update-pkgs and cve-watch bots
    "slopulus@lassul.us" = { };
    # hermes-dma (machines/styx/hermes-dma.nix): pushes to the dma repo
    # on knot.lassul.us
    "hermes-dma@lassul.us" = {
      handle = "hermes-dma";
      sshKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKoO181Z9NikLcZcNma4swobqS4xq2QEwAlSZXOWe5Jl hermes-dma@dma.lassul.us"
      ];
    };
    # Domi A., administrates dma.lassul.us with lass
    "dominik_a@gmx.de".handle = "domi";
  };

  reconcileConfig = pkgs.writeText "pds-reconcile.json" (
    builtins.toJSON {
      zitadel = {
        url = "http://127.0.0.1:${toString config.services.zitadel.settings.Port}";
        domain = config.services.zitadel.settings.ExternalDomain;
        tokenFile = "/run/credentials/pds-reconcile.service/zitadel-token";
      };
      pds = {
        url = "http://${cfg.settings.server.host}:${toString cfg.settings.server.port}";
        hostname = domain;
        database = cfg.settings.database.url;
      };
      stateFile = "/var/lib/pds-reconcile/keys.json";
      accounts = lib.mapAttrs (_: account: {
        handle = account.handle or null;
        sshKeys = account.sshKeys or [ ];
      }) accounts;
    }
  );
in
{
  lass.ports.${toString cfg.settings.server.port} = "tranquil-pds";

  # ATProto PDS (Tranquil). Accounts get handles <name>.pds.lassul.us and
  # log in via id.lassul.us. Accounts are created by pds-reconcile (see
  # accounts above) or by the SSO signup (no invite code), nginx rejects all
  # other account-creation routes.
  clan.core.vars.generators.tranquil-pds = {
    files."secrets.env" = { };
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      for var in JWT_SECRET DPOP_SECRET MASTER_KEY; do
        echo "$var=$(openssl rand -hex 32)"
      done > "$out/secrets.env"
    '';
  };

  # send-only mailbox on this host's mailserver (configs/mailserver.nix) for
  # email verification and password resets
  mailserver.loginAccounts."pds@lassul.us" = {
    hashedPasswordFile = config.clan.core.vars.generators.mailserver-pds.files."password-hash".path;
    sendOnly = true;
  };

  # smarthost.env is an environmentFile of tranquil-pds
  clan.core.vars.generators.mailserver-pds = {
    files."smarthost.env" = { };
    files."password-hash" = { };
    runtimeInputs = with pkgs; [
      coreutils
      mkpasswd
      pwgen
    ];
    script = ''
      password=$(pwgen -s 32 1)
      echo "MAIL_SMARTHOST_PASSWORD=$password" > "$out/smarthost.env"
      mkpasswd -sm bcrypt <<< "$password" > "$out/password-hash"
    '';
  };

  services.tranquil-pds = {
    enable = true;
    inherit package;
    database.createLocally = true;
    environmentFiles = [
      config.clan.core.vars.generators.tranquil-pds.files."secrets.env".path
      config.clan.core.vars.generators.mailserver-pds.files."smarthost.env".path
      zitadelEnv
    ];
    settings = {
      server = {
        hostname = domain;
        invite_code_required = false;
        # certs come from nginx, not caddy
        enable_caddy_on_demand_tls = false;
      };
      frontend.dir = package.frontend;
      # upstream default (100) equals postgres' max_connections; after a
      # postgres restart the pool took 85 slots and starved synapse, niks3 & co
      database = {
        max_connections = 10;
        min_connections = 2;
      };
      # owner's PLC recovery key (public part)
      secrets.plc_rotation_key = "did:key:zDnaepKZiYEbndTH9NNqoZUa7mvbhdiF3M9g2MCjtnxhijtUS";
      email = {
        from_address = "pds@lassul.us";
        from_name = "lassul.us PDS";
        smarthost = {
          host = "mail.lassul.us";
          port = config.lass.servicePorts.postfix-submissions;
          tls = "implicit";
        };
      };
      sso.oidc = {
        issuer = "https://id.lassul.us";
        display_name = "lassul.us ID";
      };
    };
  };

  systemd.services.tranquil-pds = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
    # not in settings: the config file is validated at build time, without
    # the secrets from environmentFiles that these require
    environment = {
      MAIL_SMARTHOST_USERNAME = "pds@lassul.us";
      SSO_OIDC_ENABLED = "true";
    };
  };

  systemd.services.pds-reconcile = {
    description = "Create the accounts of ${domain}";
    wantedBy = [ "multi-user.target" ];
    requires = [ "tranquil-pds.service" ];
    wants = [ "zitadel-reconcile.service" ];
    after = [
      "tranquil-pds.service"
      # creates the Zitadel users of new addresses
      "zitadel-reconcile.service"
    ];
    path = [ config.services.postgresql.package ];
    environment.PYTHONUNBUFFERED = "1";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # peer authentication to tranquil-pds' database
      User = cfg.user;
      Group = cfg.group;
      LoadCredential = "zitadel-token:${config.services.zitadel.steps.FirstInstance.PatPath}";
      ExecStart = "${
        lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.pds-reconcile
      } ${reconcileConfig}";
      StateDirectory = "pds-reconcile";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
  };

  lass.zitadel.projects.pds = {
    access = "declarative";
    users = lib.attrNames accounts;
    invite = {
      enable = true;
      applicationName = "lassul.us PDS";
    };
    apps.web = {
      redirectUris = [ "https://${domain}/oauth/sso/callback" ];
      authMethod = "post";
      envFile = {
        clientIdVariable = "SSO_OIDC_CLIENT_ID";
        clientSecretVariable = "SSO_OIDC_CLIENT_SECRET";
      };
    };
  };

  # repos, accounts and keys in postgres, blobs on disk
  lass.backup.state.tranquil-pds = {
    folders = [ cfg.dataDir ];
    preBackup = ''
      mkdir -p /var/backup/postgresql
      ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
        tranquil-pds | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/tranquil-pds.sql.gz
    '';
  };

  # handles are served /.well-known/atproto-did on <handle>.pds.lassul.us;
  # DNS-01 against our own knot, see _acme-challenge.pds.lassul.us in
  # configs/dns/knot.nix
  security.acme.certs.${domain} = {
    extraDomainNames = [ "*.${domain}" ];
    dnsProvider = "rfc2136";
    # recursive resolvers may have cached the *.lassul.us wildcard for
    # _acme-challenge.pds, which makes lego pick the lassul.us zone
    dnsResolver = "ns1.lassul.us:53";
    environmentFile = config.clan.core.vars.generators.knot-acme-review.files."lego.env".path;
    group = config.services.nginx.group;
  };

  services.nginx.virtualHosts.${domain} = {
    serverAliases = [ "*.${domain}" ];
    useACMEHost = domain;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${cfg.settings.server.host}:${toString cfg.settings.server.port}";
      recommendedProxySettings = true;
      # com.atproto.sync.subscribeRepos
      proxyWebsockets = true;
      extraConfig = ''
        proxy_read_timeout 1d;
        client_max_body_size 10G;
      '';
    };
    # password, passkey, delegated and migrated (service-auth) accounts
    locations."= /xrpc/com.atproto.server.createAccount".return = "403";
    locations."= /xrpc/_account.createPasskeyAccount".return = "403";
    locations."= /xrpc/_delegation.createDelegatedAccount".return = "403";
  };
}
