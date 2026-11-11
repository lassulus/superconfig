# https://sunshine.lassul.us: moonlight-web-stream, a Moonlight client in the
# browser, for every machine running Sunshine via configs/sunray.nix. It
# talks Moonlight to the hosts over retiolum and WebRTC to the browser.
# Login on id.lassul.us; who may log in is decided by the grant on the
# Zitadel project below. Every host is paired declaratively: the client
# identity below is trusted by each host's Sunshine (configs/sunray.nix),
# and each host's server cert comes from its sunshine-server var.
let
  domain = "sunshine.lassul.us";
  port = 8777;
  oauth2ProxyPort = 4184;
  # One UDP port per running stream (WebRTC)
  webrtcPorts = {
    min = 40000;
    max = 40009;
  };
  stateDir = "/var/lib/sunshine-web";
in
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  ports = config.lass.servicePorts;
  oauth2Proxy = "127.0.0.1:${toString ports.sunshine-web-oauth2-proxy}";
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.moonlight-web-stream;
  client = config.clan.core.vars.generators.sunshine-web-client.files;

  # Every machine with a Sunshine server cert (the sunshine-server var of
  # configs/sunray.nix), found in the vars dir instead of evaluating every
  # machine's config (that cost neoprism's eval ~1 GB).
  vars = self + "/vars/per-machine";
  sunshineHosts = lib.filterAttrs (
    name: type:
    type == "directory" && builtins.pathExists "${vars}/${name}/sunshine-server/cert.pem/value"
  ) (builtins.readDir vars);

  # Global hosts (owner null) of the app's data file (V3 of
  # src/app/storage/json/versions.rs), keyed by an id derived from the
  # machine name so it stays the same across restarts.
  hostId =
    name: toString (lib.fromHexString (builtins.substring 0 7 (builtins.hashString "sha256" name)));
  hosts = pkgs.writeText "sunshine-web-hosts.json" (
    builtins.toJSON (
      lib.mapAttrs' (
        name: _:
        lib.nameValuePair (hostId name) {
          owner = null;
          address = self.inputs.kartei.hosts.${name}.nets.retiolum.ip4.addr;
          # configs/sunray.nix keeps Sunshine's default port
          http_port = config.services.sunshine.settings.port;
          server_certificate = builtins.readFile "${vars}/${name}/sunshine-server/cert.pem/value";
          cache = {
            inherit name;
            mac = null;
          };
        }
      ) sunshineHosts
    )
  );

  settings = (pkgs.formats.json { }).generate "sunshine-web.json" {
    data_storage = {
      type = "json";
      path = "${stateDir}/data.json";
      session_expiration_check_interval = {
        secs = 300;
        nanos = 0;
      };
    };
    webrtc = {
      # neoprism has its public address on an interface, so its host
      # candidates are reachable and the browser's are learned from its
      # connectivity checks; no (Google) STUN or TURN server needed.
      ice_servers = [ ];
      port_range = webrtcPorts;
      include_loopback_candidates = false;
    };
    web_server = {
      bind_address = "127.0.0.1:${toString ports.sunshine-web}";
      # Users come from the header nginx sets (oauth2-proxy's email) and get
      # the default role (a User role the app creates, allowed to stream).
      # No admin and no password logins.
      forwarded_header = {
        username_header = "X-Forwarded-User";
        auto_create_missing_user = true;
      };
      first_login_create_admin = false;
      first_login_assign_global_hosts = false;
    };
  };
in
{
  lass.ports = {
    ${toString port} = "sunshine-web";
    ${toString oauth2ProxyPort} = "sunshine-web-oauth2-proxy";
  }
  // lib.genAttrs (map toString (lib.range webrtcPorts.min webrtcPorts.max)) (
    p: "sunshine-web-webrtc-${p}"
  );

  networking.firewall.allowedUDPPortRanges = [
    {
      from = webrtcPorts.min;
      to = webrtcPorts.max;
    }
  ];

  # The identity the app pairs with: an RSA 2048 self-signed cert like the
  # ones Moonlight and Sunshine generate (v3, no CA flag; 20 years, as
  # Sunshine rejects expired client certs). The sunray hosts trust the cert
  # (configs/sunray.nix reads it from this machine's config); the key stays
  # here. Not a shared generator: clan deploys a shared generator's secrets
  # to every machine declaring it, and `deploy` can't differ between them.
  clan.core.vars.generators.sunshine-web-client = {
    files."cert.pem".secret = false;
    files."key.pem".owner = "sunshine-web";
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      printf '[req]\ndistinguished_name = dn\n[dn]\n' > req.cnf
      openssl req -x509 -config req.cnf -newkey rsa:2048 -nodes -sha256 -days 7300 \
        -subj "/CN=${domain}" -keyout "$out/key.pem" -out "$out/cert.pem"
    '';
  };

  users.users.sunshine-web = {
    isSystemUser = true;
    group = "sunshine-web";
  };
  users.groups.sunshine-web = { };

  systemd.services.sunshine-web = {
    description = "${domain} Moonlight web client";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.jq ];
    # Puts the Nix hosts into the data file, paired with the client identity:
    # replaces all global hosts (only Nix creates them, there is no admin),
    # keeps users, roles, defaults and the hosts users added themselves.
    preStart = ''
      data=${stateDir}/data.json
      if [ ! -s "$data" ]; then
        echo '{"version": "3", "users": {}, "hosts": {}, "roles": {}}' > "$data"
      fi
      jq \
        --slurpfile nix ${hosts} \
        --rawfile key ${client."key.pem".path} \
        --rawfile cert ${client."cert.pem".path} \
        '.hosts = (
          (.hosts | with_entries(select(.value.owner != null)))
          + ($nix[0] | map_values({
              owner, address, http_port, cache,
              pair_info: {
                client_private_key: $key,
                client_certificate: $cert,
                server_certificate
              }
            }))
        )' "$data" > "$data.tmp"
      mv "$data.tmp" "$data"
    '';
    serviceConfig = {
      ExecStart = "${lib.getExe package} --config-path ${settings}";
      User = "sunshine-web";
      Group = "sunshine-web";
      StateDirectory = "sunshine-web";
      UMask = "0077";
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
    };
  };

  lass.backup.state.sunshine-web.folders = [ stateDir ];

  lass.zitadel.projects.sunshine = {
    access = "managed";
    apps.web = {
      redirectUris = [ "https://${domain}/oauth2/callback" ];
      envFile = {
        clientIdVariable = "OAUTH2_PROXY_CLIENT_ID";
        clientSecretVariable = "OAUTH2_PROXY_CLIENT_SECRET";
      };
    };
  };
  # services.oauth2-proxy is single-instance and taken by assist.lassul.us
  # (configs/hermes-proxy.nix), so this is its own unit.
  systemd.services.sunshine-web-oauth2-proxy = {
    description = "${domain} login (id.lassul.us)";
    wantedBy = [ "multi-user.target" ];
    wants = [ "zitadel-reconcile.service" ];
    after = [
      "network-online.target"
      "zitadel-reconcile.service"
    ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.oauth2-proxy)
        "--provider=oidc"
        "--oidc-issuer-url=https://id.lassul.us"
        "--redirect-url=https://${domain}/oauth2/callback"
        "--http-address=${oauth2Proxy}"
        # who may log in is decided by the grant on the Zitadel project
        "--email-domain=*"
        # X-Auth-Request-Email on /oauth2/auth, the app's user name
        "--set-xauthrequest=true"
        "--cookie-name=_sunshine_oauth2"
        "--cookie-secret-file=%d/cookie-secret"
        "--cookie-secure=true"
        "--skip-provider-button=true"
      ];
      EnvironmentFile = config.lass.zitadel.projects.sunshine.apps.web.envFile.path;
      LoadCredential = "cookie-secret:${
        config.clan.core.vars.generators.sunshine-web-oauth2-proxy.files."cookie-secret".path
      }";
      DynamicUser = true;
      Restart = "on-failure";
    };
  };
  clan.core.vars.generators.sunshine-web-oauth2-proxy = {
    files."cookie-secret" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/cookie-secret"
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations = {
      "/" = {
        proxyPass = "http://127.0.0.1:${toString ports.sunshine-web}";
        # the WebSocket transport (/api/host/stream/web_socket), the
        # fallback when WebRTC can't connect; WebRTC signals over plain HTTP
        proxyWebsockets = true;
        extraConfig = ''
          auth_request /oauth2/auth;
          error_page 401 = @login;
          # the logged-in user for the app; replaces any X-Forwarded-User
          # the client sent
          auth_request_set $sunshine_user $upstream_http_x_auth_request_email;
          proxy_set_header X-Forwarded-User $sunshine_user;
        '';
      };
      "/oauth2/" = {
        recommendedProxySettings = true;
        proxyPass = "http://${oauth2Proxy}";
      };
      "= /oauth2/auth" = {
        recommendedProxySettings = true;
        proxyPass = "http://${oauth2Proxy}";
        extraConfig = ''
          proxy_pass_request_body off;
          proxy_set_header Content-Length "";
        '';
      };
      "@login".return = "307 /oauth2/start?rd=$request_uri";
    };
  };
}
