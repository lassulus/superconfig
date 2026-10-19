{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # The one and only calendar, lass/calendar: own events (phone via DAVx⁵,
  # calendar.lassul.us), booking requests and bookings mirrored by tools/book
  # (configs/book.nix), and whatever Hermes adds. The rights below make it the
  # only writable collection: nobody can create, delete or replace calendars.
  calendar = "lass/calendar";

  # lass: phone, web client and tools/book.
  # hermes: the agent on coaxmetal (machines/coaxmetal/hermes.nix). Its var is
  # shared (and declared there too) so coaxmetal's hermes-env can read the
  # password without radicale running there.
  users = [
    "lass"
    "hermes"
  ];
  sharedUsers = [ "hermes" ];

  # One var per user with a random password.
  userGenerators = lib.listToAttrs (
    map (user: {
      name = "radicale-${user}";
      value = import ./radicale-user-generator.nix pkgs user // {
        share = lib.elem user sharedUsers;
      };
    }) users
  );

  loadCredentials = map (
    user:
    "radicale-${user}-htpasswd:${
      config.clan.core.vars.generators."radicale-${user}".files."htpasswd-line".path
    }"
  ) users;

  assembleHtpasswd = pkgs.writeShellScript "radicale-htpasswd" (
    lib.concatMapStringsSep "\n" (user: "cat \${CREDENTIALS_DIRECTORY}/radicale-${user}-htpasswd") users
  );

  # Calino (static, local-first CalDAV web client) on its own origin; accounts
  # and settings stay in the browser, so nothing is stored server-side. Log in
  # with server https://cal.lassul.us/ and a radicale user.
  webClient = "calendar.lassul.us";
  calino = self.packages.${pkgs.stdenv.hostPlatform.system}.calino;

  proxyHeaders = ''
    proxy_set_header X-Script-Name /;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $host;
  '';

  # CORS for the web client; see the maps in appendHttpConfig below.
  cors = ''
    add_header Access-Control-Allow-Origin $radicale_cors_origin always;
    add_header Access-Control-Allow-Methods "GET, PUT, DELETE, PROPFIND, PROPPATCH, REPORT, OPTIONS, MKCOL, MKCALENDAR, MOVE" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, Depth, Prefer, If-Match, If-None-Match" always;
    add_header Access-Control-Expose-Headers "ETag, Location, DAV, Allow, X-Sync-Token" always;
    add_header Access-Control-Max-Age 86400 always;
    add_header Vary Origin always;
    if ($radicale_cors_preflight) {
      return 204;
    }
  '';
in
{
  services.radicale = {
    enable = true;
    settings = {
      server = {
        hosts = [ "127.0.0.1:5232" ];
      };
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/run/radicale/htpasswd";
        htpasswd_encryption = "bcrypt";
      };
      storage = {
        filesystem_folder = "/var/lib/radicale/collections";
      };
      web = {
        type = "internal";
      };
    };
    # Whitelist, first match wins (sections are emitted sorted by name, hence
    # the numeric prefixes); anything unmatched is denied. Every user reads and
    # writes the events of the one calendar (d/o: but may not delete or
    # overwrite the collection itself) and may only read the root and lass's
    # home, which is enough for CalDAV discovery. No W/w anywhere else, so no
    # MKCALENDAR and no auto-created principals.
    rights =
      let
        anyUser = lib.concatStringsSep "|" users;
      in
      {
        "10-calendar" = {
          user = anyUser;
          collection = calendar;
          permissions = "rwdo";
        };
        "20-root" = {
          user = anyUser;
          collection = "";
          permissions = "R";
        };
        "21-home" = {
          user = anyUser;
          collection = lib.head (lib.splitString "/" calendar);
          permissions = "R";
        };
      };
  };

  lass.backup.state.radicale.folders = [ "/var/lib/radicale" ];

  systemd.services.radicale.serviceConfig = {
    RuntimeDirectory = "radicale";
    LoadCredential = loadCredentials;
  };
  systemd.services.radicale.preStart = lib.mkBefore ''
    ${assembleHtpasswd} > /run/radicale/htpasswd
  '';

  clan.core.vars.generators = userGenerators;

  # Let the web client's origin talk CalDAV to radicale. Preflights carry no
  # credentials and are answered here; a plain DAV OPTIONS (no
  # Access-Control-Request-Method) still reaches radicale.
  services.nginx.appendHttpConfig = ''
    map $http_origin $radicale_cors_origin {
      default "";
      "https://${webClient}" $http_origin;
    }
    map "$request_method:$http_access_control_request_method" $radicale_cors_preflight {
      default 0;
      "~^OPTIONS:." 1;
    }
    # Top-level navigations send no Origin; the web client's GET / probes
    # (CalDAV discovery via /.well-known/caldav) do and must reach radicale.
    map "$request_method:$http_origin" $radicale_root_redirect {
      default 0;
      "GET:" 1;
    }
  '';

  services.nginx.virtualHosts."cal.lassul.us" = {
    forceSSL = true;
    enableACME = true;
    # Browsers opening the bare domain get the web client; CalDAV discovery
    # (PROPFIND /, or the web client's cross-origin GET /) still reaches
    # radicale.
    locations."= /" = {
      proxyPass = "http://127.0.0.1:5232";
      extraConfig =
        cors
        + ''
          if ($radicale_root_redirect) {
            return 302 https://${webClient}/;
          }
        ''
        + proxyHeaders;
    };
    locations."/" = {
      proxyPass = "http://127.0.0.1:5232";
      extraConfig = cors + proxyHeaders;
    };
  };

  services.nginx.virtualHosts.${webClient} = {
    forceSSL = true;
    enableACME = true;
    root = calino;
    locations."/".extraConfig = ''
      try_files $uri /index.html;
      add_header Cache-Control no-cache;
    '';
    # Vite puts content-hashed bundles here.
    locations."/assets/".extraConfig = ''
      add_header Cache-Control "public, max-age=31536000, immutable";
    '';
  };
}
