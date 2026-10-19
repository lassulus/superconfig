{
  self,
  config,
  pkgs,
  ...
}:
let
  domain = "pds.lassul.us";
  cfg = config.services.tranquil-pds;
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.tranquil-pds;
  zitadelEnv = config.lass.zitadel.projects.pds.apps.web.envFile.path;
in
{
  # ATProto PDS (Tranquil). Accounts get handles <name>.pds.lassul.us and
  # log in via id.lassul.us. Accounts are created only by the SSO signup
  # (no invite code), nginx rejects all other account-creation routes.
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
      # owner's PLC recovery key (public part)
      secrets.plc_rotation_key = "did:key:zDnaepKZiYEbndTH9NNqoZUa7mvbhdiF3M9g2MCjtnxhijtUS";
      email = {
        from_address = "pds@lassul.us";
        from_name = "lassul.us PDS";
        smarthost = {
          host = "mail.lassul.us";
          port = 465;
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

  # only the users listed here get a project grant and can log in
  lass.zitadel.projects.pds = {
    access = "declarative";
    users = [ "lass@lassul.us" ];
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
