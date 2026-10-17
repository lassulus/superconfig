let
  domain = "book.lassul.us";
  port = 8772;
in
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  settings = {
    listen = "127.0.0.1:${toString port}";
    baseUrl = "https://${domain}";
    owner = "lassulus";
    intro = "Pick a time for a call: nix, nixos, infrastructure, or anything else.";
    timezone = "Europe/Berlin";
    eventTypes = [
      {
        slug = "30min";
        title = "30 minute call";
        minutes = 30;
      }
      {
        slug = "60min";
        title = "1 hour call";
        minutes = 60;
      }
    ];
    hours = lib.genAttrs [ "mon" "tue" "wed" "thu" "fri" ] (_: [ "10:00-18:00" ]);
    slotStep = 30;
    bufferMinutes = 15;
    minNoticeHours = 24;
    horizonDays = 28;
    # lass/calendar is the only calendar (configs/radicale.nix): free/busy is
    # read from it, and requests and bookings are mirrored into it, next to
    # lass's own events and whatever Hermes adds. Book reads its events back:
    # deleting, moving or confirming one there manages the booking.
    caldav = {
      url = "http://127.0.0.1:5232";
      user = "lass";
      calendar = "calendar";
    };
    # Local postfix (configs/mailserver.nix) accepts from localhost and DKIM-signs.
    smtp = {
      host = "127.0.0.1";
      port = 25;
      from = "book@lassul.us";
      notify = "lass@lassul.us";
    };
    database = "/var/lib/book/book.db";
  };
in
{
  # book: request-and-approve booking page (tools/book). Requests land in
  # radicale (configs/radicale.nix) as TENTATIVE events and in lass's inbox
  # with an approve link.
  systemd.services.book = {
    description = "book.lassul.us booking page";
    wantedBy = [ "multi-user.target" ];
    wants = [ "radicale.service" ];
    after = [
      "network.target"
      "radicale.service"
    ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.book)
        "--config"
        (pkgs.writeText "book.json" (builtins.toJSON settings))
        "--caldav-password-file"
        "%d/caldav-password"
        "--busy-token-file"
        "%d/busy-token"
      ];
      LoadCredential = [
        "caldav-password:${config.clan.core.vars.generators.radicale-lass.files."password".path}"
        "busy-token:${config.clan.core.vars.generators.busy-feed.files."token".path}"
      ];
      DynamicUser = true;
      StateDirectory = "book";
      Restart = "on-failure";
      CapabilityBoundingSet = "";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
    };
  };

  # Secret of the busy-only feed https://cal.lassul.us/busy/<token>.ics, for
  # the availability polls on when.lassul.us (configs/timeful.nix).
  clan.core.vars.generators.busy-feed = {
    files."token" = { };
    runtimeInputs = [ pkgs.coreutils ];
    script = ''
      head -c 24 /dev/urandom | basenc --base64url | tr -d '\n' > "$out/token"
    '';
  };

  # book answers 404 for every /busy/ path but the one with the token.
  services.nginx.virtualHosts."cal.lassul.us".locations."/busy/" = {
    proxyPass = "http://127.0.0.1:${toString port}";
    extraConfig = ''
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      # book rate-limits per X-Real-IP; set it from the socket, never from
      # a client-supplied header.
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        client_max_body_size 16k;
      '';
    };
    # The busy feed is served on cal.lassul.us only.
    locations."/busy/".return = "404";
  };
}
