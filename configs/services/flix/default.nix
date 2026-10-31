{
  self,
  config,
  lib,
  pkgs,
  ...
}:
{
  # sabnzbd hard-depends on cheetah3, whose PyPI dist is `ct3` while nixpkgs
  # sets pname="cheetah3". pythonMetadataCheckPhase then looks up metadata for
  # "cheetah3", finds only "ct3", and fails the build with PackageNotFoundError.
  # Skip that spurious check until nixpkgs fixes the pname/dist mismatch.
  nixpkgs.overlays = [
    (_final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (_pyfinal: pyprev: {
          cheetah3 = pyprev.cheetah3.overridePythonAttrs (_: {
            dontCheckPythonMetadata = true;
          });
        })
      ];
    })
  ];
  users.users.download = {
    isSystemUser = true;
    uid = 1001;
    group = "download";
  };
  users.groups.download.members = [
    "transmission"
    "sabnzbd"
  ];
  services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    home = "/var/state/transmission";
    group = "download";
    downloadDirPermissions = "775";
    settings = {
      download-dir = "/var/download/transmission";
      incomplete-dir-enabled = false;
      rpc-bind-address = "::";
      message-level = 1;
      # 0o002: files 664 so sonarr/radarr (group download) can hardlink
      # instead of copying (fs.protected_hardlinks needs owner or write)
      umask = 2;
      rpc-whitelist-enabled = false;
      rpc-host-whitelist-enabled = false;
      # stop seeding after reaching 5.0 ratio
      ratio-limit = 5;
      ratio-limit-enabled = true;
      # limit concurrent seeding to reduce resource usage
      seed-queue-enabled = true;
      seed-queue-size = 20;
    };
  };

  # garbage collection for old torrents
  systemd.services.transmission-gc = {
    description = "Remove old completed torrents from Transmission";
    after = [ "transmission.service" ];
    path = [
      pkgs.transmission_4
      pkgs.jq
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.findutils
    ];
    script = ''
      set -efu
      # transmission lives in its own netns (t1 = 128.0.0.1/30), this unit runs
      # outside it (t2 = 128.0.0.2), so localhost is *not* the daemon here.
      TRANSMISSION_HOST="128.0.0.1:9091"
      MAX_AGE_DAYS=30
      MIN_RATIO=5.0

      # get list of all torrents as JSON
      torrents=$(transmission-remote "$TRANSMISSION_HOST" -l 2>/dev/null | tail -n +2 | head -n -1 || true)

      if [ -z "$torrents" ]; then
        echo "No torrents found"
        exit 0
      fi

      # process each torrent
      echo "$torrents" | while read -r line; do
        id=$(echo "$line" | awk '{print $1}' | tr -d '*')
        # skip if not a valid ID
        [ -z "$id" ] || [ "$id" = "ID" ] && continue

        # get torrent info
        info=$(transmission-remote "$TRANSMISSION_HOST" -t "$id" -i 2>/dev/null || continue)

        # extract ratio and completion status
        ratio=$(echo "$info" | grep "Ratio:" | awk '{print $2}')
        percent=$(echo "$info" | grep "Percent Done:" | awk '{print $3}' | tr -d '%')
        state=$(echo "$info" | grep "State:" | cut -d: -f2- | xargs)

        # skip if not 100% complete
        [ "$percent" != "100" ] && continue

        # check if ratio reached
        ratio_reached=false
        if [ -n "$ratio" ] && [ "$ratio" != "None" ]; then
          if awk "BEGIN {exit !($ratio >= $MIN_RATIO)}"; then
            ratio_reached=true
          fi
        fi

        # check age via date added
        date_added=$(echo "$info" | grep "Date added:" | cut -d: -f2- | xargs)
        if [ -n "$date_added" ]; then
          added_epoch=$(date -d "$date_added" +%s 2>/dev/null || echo 0)
          now_epoch=$(date +%s)
          age_days=$(( (now_epoch - added_epoch) / 86400 ))
        else
          age_days=0
        fi

        # remove if ratio reached OR older than max age
        if [ "$ratio_reached" = "true" ]; then
          echo "Removing torrent $id (ratio: $ratio >= $MIN_RATIO)"
          transmission-remote "$TRANSMISSION_HOST" -t "$id" --remove-and-delete
        elif [ "$age_days" -ge "$MAX_AGE_DAYS" ]; then
          echo "Removing torrent $id (age: $age_days days >= $MAX_AGE_DAYS)"
          transmission-remote "$TRANSMISSION_HOST" -t "$id" --remove-and-delete
        fi
      done
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "transmission";
    };
  };

  systemd.timers.transmission-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
  systemd.services.transmission-watcher = {
    wantedBy = [ "multi-user.target" ];
    startAt = "*:0/5";
    path = [
      pkgs.curl
      pkgs.systemdMinimal
    ];
    script = ''
      set -efu -o pipefail
      # don't restart if transmission is currently starting or stopping
      state=$(systemctl show -p ActiveState --value transmission.service)
      if [ "$state" = "activating" ] || [ "$state" = "deactivating" ]; then
        echo "transmission is $state, skipping"
        exit 0
      fi
      # check if transmission responds (with timeout)
      if ! curl -SsfL --max-time 10 http://transmission.r; then
        echo "transmission not responding, restarting"
        systemctl restart transmission.service
      fi
    '';
  };

  # pause downloads when /var/download runs low, so a full disk can no longer
  # hard-wedge sabnzbd with an unrecoverable "Disk full! Forcing Pause".
  # sabnzbd pauses itself once free disk drops below download_free/complete_free
  # and only auto-resumes above if fulldisk_autoresume is set (default off);
  # this guard keeps those at THRESH GiB / on, and additionally sends a resume
  # on recovery. Transmission has no equivalent, so below the threshold the
  # guard stops all its torrents (restarting them on recovery) and posts a
  # Matrix alert on each transition.
  systemd.services.download-space-guard = {
    wantedBy = [ "multi-user.target" ];
    after = [ "sabnzbd.service" ];
    startAt = "*:0/5";
    path = [
      pkgs.curl
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.jq
      pkgs.transmission_4
    ];
    script = ''
      set -efu
      DIR=/var/download
      THRESH=100
      # !MRjkvAaFPsjdYCpeiZ:lassul.us, URL-encoded for the API path
      ROOM=%21MRjkvAaFPsjdYCpeiZ%3Alassul.us
      STATE="$STATE_DIRECTORY/state"

      avail=$(df -Pk "$DIR" | awk 'NR==2 {print int($4 / 1024 / 1024)}')

      INI=/var/lib/sabnzbd/sabnzbd.ini
      key=$(grep -E '^api_key' "$INI" | head -1 | cut -d= -f2 | tr -d ' ')
      sab() {
        curl -fsS --max-time 15 "http://127.0.0.1:8080/api?output=json&apikey=$key&$1" >/dev/null || :
      }
      tr_remote() {
        transmission-remote 128.0.0.1:9091 "$@" >/dev/null || :
      }
      notify() {
        token=$(cat "$CREDENTIALS_DIRECTORY/matrix-token")
        body=$(jq -nc --arg b "$1" '{msgtype: "m.text", body: $b}')
        curl -fsS --max-time 15 -X POST \
          -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
          "https://matrix.lassul.us/_matrix/client/v3/rooms/$ROOM/send/m.room.message" \
          --data "$body" >/dev/null || :
      }

      # sabnzbd pauses continuously once free disk drops below these; keep
      # them at THRESH GiB and auto-resume on; re-assert only if changed.
      for k in download_free complete_free; do
        grep -qxF "$k = ''${THRESH}G" "$INI" \
          || sab "mode=set_config&section=misc&keyword=$k&value=''${THRESH}G"
      done
      grep -qxF "fulldisk_autoresume = 1" "$INI" \
        || sab "mode=set_config&section=misc&keyword=fulldisk_autoresume&value=1"

      prev=ok
      if [ -f "$STATE" ]; then prev=$(cat "$STATE"); fi
      if [ "$avail" -lt "$THRESH" ]; then cur=low; else cur=ok; fi

      if [ "$cur" = low ]; then
        # stop everything each run so newly-grabbed torrents can't fill the disk
        tr_remote -t all --stop
        if [ "$prev" != low ]; then
          echo "free ''${avail}G < ''${THRESH}G: stopped transmission, alerting"
          notify "⚠️ yellow: /var/download down to ''${avail} GiB free (< ''${THRESH} GiB). Stopped all transmission torrents; sabnzbd auto-paused via download_free."
        fi
      elif [ "$prev" = low ]; then
        echo "free ''${avail}G >= ''${THRESH}G: resumed transmission and sabnzbd, alerting"
        tr_remote -t all --start
        sab "mode=resume"
        notify "✅ yellow: /var/download recovered to ''${avail} GiB free. Resumed sabnzbd and transmission torrents."
      fi
      echo "$cur" > "$STATE"
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      StateDirectory = "download-space-guard";
      LoadCredential = [
        "matrix-token:${config.clan.core.vars.generators.archiver-matrix.files."matrix-access-token".path}"
      ];
    };
  };

  security.acme.defaults.email = "spam@krebsco.de";
  security.acme.acceptTerms = true;
  services.nginx = {
    enable = true;
    package = pkgs.nginx.override {
      modules = with pkgs.nginxModules; [
        fancyindex
      ];
    };
    virtualHosts."yellow.r" = {
      serverAliases = [ "flix.r" ];
      default = true;
      locations."/" = {
        root = "/var/download";
        extraConfig = ''
          fancyindex on;
          include ${pkgs.nginx}/conf/mime.types;
          include ${pkgs.writeText "extrMime" ''
            types {
              video/webm mkv;
            }
          ''};
          create_full_put_path on;
        '';
      };

    };
    virtualHosts."jelly.r" = {
      locations."/".extraConfig = ''
        proxy_pass http://localhost:8096/;
        proxy_set_header Accept-Encoding "";
      '';
    };
    virtualHosts."transmission.r" = {
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "http://128.0.0.1:9091";
      };
    };
    virtualHosts."radar.r" = {
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "http://localhost:7878";
      };
    };
    virtualHosts."sonar.r" = {
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "http://localhost:8989";
        # sonar.r now has forced authentication
        extraConfig = ''
          proxy_set_header Authorization "Basic a3JlYnM6YWlkc2JhbGxz";
        '';
      };
    };
  };

  services.samba = {
    enable = true;
    enableNmbd = false;
    settings.global = {
      "hosts allow" = "42::/16 10.243.0.0/16 10.244.0.0/16 fdcc:c5da:5295:c853:d499::/80";
      "use sendfile" = "true";
      "disable netbios" = "true";
      "mangled names" = "illegal";
      "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=65536 SO_SNDBUF=65536";
      "load printers" = "false";
      "disable spoolss" = "true";
      "printcap name" = "/dev/null";
      "map to guest" = "Bad User";
      "max log size" = "50";
      "dns proxy" = "no";
      "security" = "user";
      "syslog only" = "yes";
    };
    shares.public = {
      comment = "Warez";
      path = "/var/download";
      public = "yes";
      "only guest" = "yes";
      "create mask" = "0644";
      "directory mask" = "2777";
      writable = "no";
      printable = "no";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80 # nginx
    443 # nginx
    config.lass.servicePorts.gamarr
    9091 # transmission web
    8096 # jellyfin
    8920 # jellyfin
    51413 # transmission traffic
    445 # smbd
    111 # smbd
    2049 # smbd
    4000 # smbd
    4001 # smbd
    4002 # smbd
  ];
  networking.firewall.allowedUDPPorts = [
    51413 # transmission traffic
    1900 # jellyfin
    7359 # jellyfin
    111 # smbd
    2049 # smbd
    4000 # smbd
    4001 # smbd
    4002 # smbd
  ];
  # we need this so we can forward into the the transmission network namespace
  networking.firewall.filterForward = false;
  # transmission rpc port
  networking.nftables.tables.flix = {
    family = "ip6";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "retiolum" tcp dport 9091 dnat to fdb4:3310:947::2
      }
    '';
  };

  systemd.services.flix-index = {
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.inotify-tools
    ];
    startAt = "hourly";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writers.writeDash "flix-index" ''
        set -efu
        index(){
          # /var/download churns constantly (download temp files appearing and
          # vanishing), so find can exit non-zero when an entry disappears
          # mid-scan. Ignore that — the entries we did enumerate are still valid
          # — but only replace the live index if we actually produced one.
          find . -type f > "$DIR"/index.tmp || :
          if [ -s "$DIR"/index.tmp ]; then
            mv "$DIR"/index.tmp "$DIR"/index
          fi
        }

        DIR=/var/download
        cd "$DIR"
        index
      '';
    };
  };

  services.jellyfin = {
    enable = true;
    group = "download";
  };

  # request managment
  services.jellyseerr = {
    enable = true;
    openFirewall = true;
  };

  # movies
  services.radarr = {
    enable = true;
    openFirewall = true;
    user = "download";
    group = "download";
  };

  # shows
  services.sonarr = {
    enable = true;
    openFirewall = true;
    user = "download";
    group = "download";
  };
  # games, web ui on yellow.r:6969 (its default 6767 is bazarr's)
  lass.ports."6969" = "gamarr";
  systemd.services.gamarr = {
    environment.GAMARR__SERVER__PORT = toString config.lass.servicePorts.gamarr;
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "download";
      Group = "download";
      StateDirectory = "gamarr";
      ExecStart = "${
        self.packages.${pkgs.stdenv.hostPlatform.system}.gamarr
      }/bin/Gamarr -nobrowser -data=/var/lib/gamarr";
      Restart = "on-failure";
    };
  };
  systemd.tmpfiles.settings.gamarr."/var/download/games".d = {
    user = "download";
    group = "download";
    mode = "0775";
  };

  # sonarr needs unsecure packages
  nixpkgs.config.permittedInsecurePackages = [
    "aspnetcore-runtime-wrapped-6.0.36"
    "aspnetcore-runtime-6.0.36"
    "dotnet-sdk-wrapped-6.0.428"
    "dotnet-sdk-6.0.428"
    "olm-3.2.16"
  ];

  # indexers
  services.prowlarr = {
    enable = true;
    openFirewall = true;
  };

  # flaresolverr for bypassing cloudflare on some indexers
  services.flaresolverr = {
    enable = true;
    openFirewall = true;
  };

  # subtitles
  lass.ports."6767" = "bazarr";
  services.bazarr = {
    enable = true;
    settings.general.port = config.lass.servicePorts.bazarr;
    openFirewall = true;
    user = "download";
    group = "download";
  };

  # usenet download client
  services.sabnzbd = {
    enable = true;
    group = "download";
    openFirewall = true;
  };
  # sonarr/radarr copy on import and leave the originals in sabnzbd's
  # complete_dir (/var/download/usenet) forever; purge anything untouched
  # for a week. Active imports are always younger than that.
  systemd.tmpfiles.rules = [
    "e /var/download/usenet - - - 7d"
  ];

  # Configs without media, downloads, logs and image caches; the SQLite
  # databases are dumped consistently instead of copied.
  lass.backup.state.flix =
    let
      dbs = {
        jellyfin = "/var/lib/jellyfin/data/*.db";
        sonarr = "${config.services.sonarr.dataDir}/sonarr.db";
        radarr = "${config.services.radarr.dataDir}/radarr.db";
        prowlarr = "/var/lib/private/prowlarr/prowlarr.db";
        jellyseerr = "/var/lib/private/jellyseerr/config/db/db.sqlite3";
        sabnzbd = "/var/lib/sabnzbd/admin/history1.db";
        gamarr = "/var/lib/gamarr/gamarr.db";
      };
      dirs = [
        "/var/lib/jellyfin"
        config.services.sonarr.dataDir
        config.services.radarr.dataDir
        "/var/lib/private/prowlarr"
        "/var/lib/private/jellyseerr"
        "/var/lib/sabnzbd"
        "/var/lib/gamarr"
      ];
    in
    {
      folders = dirs;
      exclude = [
        "/var/lib/jellyfin/metadata"
        "/var/lib/jellyfin/log"
        "/var/lib/jellyfin/transcodes"
        "${config.services.sonarr.dataDir}/MediaCover"
        "${config.services.sonarr.dataDir}/logs"
        "${config.services.radarr.dataDir}/MediaCover"
        "${config.services.radarr.dataDir}/logs"
        "/var/lib/private/prowlarr/logs"
        "/var/lib/private/jellyseerr/config/cache"
        "/var/lib/private/jellyseerr/config/logs"
        "/var/lib/private/jellyseerr/config/db/db.sqlite3*"
        "/var/lib/sabnzbd/Downloads"
        "/var/lib/sabnzbd/logs"
        "/var/lib/gamarr/logs"
        "/var/lib/gamarr/MediaCover"
      ]
      # the live databases, also the unneeded servarr logs.db
      ++ map (dir: "${dir}/*.db") dirs
      ++ map (dir: "${dir}/*.db-*") dirs;
      preBackup = ''
        rm -rf /var/backup/flix
        ${lib.concatStrings (
          lib.mapAttrsToList (name: glob: ''
            mkdir -p /var/backup/flix/${name}
            for db in ${glob}; do
              # sqlite3 would create a missing database
              test -f "$db"
              ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" "$db" ".backup '/var/backup/flix/${name}/$(basename "$db")'"
            done
          '') dbs
        )}
      '';
      # WAL-mode SQLite readers need to write the -shm file
      readWritePaths = map dirOf (lib.attrValues dbs);
    };
}
