{ config, ... }:
let
  domain = "mail.lassul.us";
  zitadelEnv = config.lass.zitadel.projects.mail.apps.roundcube.envFile.path;
  # Basic-auth introspection URL with the roundcube client's id and secret,
  # read by dovecot at config parse time.
  introspectionUrl = "/var/lib/dovecot-oauth2/introspection-url";
in
{
  # Webmail on mail.lassul.us. Login only via Zitadel (id.lassul.us); roundcube
  # hands the access token to dovecot (IMAP, ManageSieve) and postfix (SMTP via
  # dovecot SASL) with OAUTHBEARER/XOAUTH2, so no mail password is stored.
  services.roundcube = {
    enable = true;
    hostName = domain;
    maxAttachmentSize = 25;
    plugins = [
      "archive"
      "managesieve"
      "zipdownload"
    ];
    extraConfig = ''
      $config['product_name'] = 'lassulus webmail';
      $config['default_list_mode'] = 'threads';
      $config['imap_host'] = 'ssl://${domain}:${toString config.lass.servicePorts.dovecot-imaps}';
      $config['smtp_host'] = 'ssl://${domain}:${toString config.lass.servicePorts.postfix-submissions}';
      $config['managesieve_host'] = 'tls://${domain}:${toString config.lass.servicePorts.dovecot-managesieve}';

      $oidc = parse_ini_file('${zitadelEnv}', false, INI_SCANNER_RAW);
      $config['oauth_provider'] = 'generic';
      $config['oauth_provider_name'] = 'lassul.us ID';
      $config['oauth_client_id'] = $oidc['CLIENT_ID'];
      $config['oauth_client_secret'] = $oidc['CLIENT_SECRET'];
      $config['oauth_config_uri'] = 'https://id.lassul.us/.well-known/openid-configuration';
      $config['oauth_scope'] = 'openid email profile offline_access';
      $config['oauth_identity_fields'] = ['email'];
      $config['oauth_login_redirect'] = true;
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = false;
    useACMEHost = domain;
  };

  # Only lass may log in; dovecot maps the token's email to the mailbox.
  lass.zitadel.projects.mail = {
    access = "declarative";
    users = [ "lass@lassul.us" ];
    apps.roundcube = {
      redirectUris = [ "https://${domain}/index.php/login/oauth" ];
      # roundcube sends the client secret in the token request body
      authMethod = "post";
      refreshTokens = true;
      envFile.owner = "roundcube";
    };
  };

  # Dovecot checks tokens at Zitadel's introspection endpoint as the roundcube
  # client. Zitadel reports a token as active only if its audience contains
  # this project, so tokens issued to other lassul.us ID apps are refused.
  services.dovecot2.settings = {
    auth_mechanisms = [
      "oauthbearer"
      "xoauth2"
    ];
    oauth2_introspection_mode = "post";
    oauth2_introspection_url = "<${introspectionUrl}";
    oauth2_force_introspection = true;
    oauth2_active_attribute = "active";
    oauth2_active_value = "true";
    oauth2_username_attribute = "email";
    oauth2.ssl_client_ca_file = "/etc/ssl/certs/ca-certificates.crt";
  };

  systemd.services.dovecot-oauth2-url = {
    wants = [ "zitadel-reconcile.service" ];
    after = [ "zitadel-reconcile.service" ];
    before = [ "dovecot.service" ];
    wantedBy = [ "dovecot.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "dovecot-oauth2";
      StateDirectoryMode = "0700";
      UMask = "0077";
      EnvironmentFile = zitadelEnv;
    };
    script = ''
      printf '%s' "https://$CLIENT_ID:$CLIENT_SECRET@id.lassul.us/oauth/v2/introspect" \
        > ${introspectionUrl}.tmp
      mv ${introspectionUrl}.tmp ${introspectionUrl}
    '';
  };
}
