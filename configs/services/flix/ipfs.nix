{
  config,
  pkgs,
  lib,
  ...
}:
let
  watchDirs = [
    "/var/lib/ipfs/download/movies"
    "/var/lib/ipfs/download/shows"
    "/var/lib/ipfs/download/games"
  ];

  cidMapFile = "/var/lib/ipfs/cid-map.txt";

  pinWatcherScript = pkgs.writers.writeBash "ipfs-pin-watcher" ''
    set -efu

    IPFS="${pkgs.kubo}/bin/ipfs"
    INOTIFYWAIT="${pkgs.inotify-tools}/bin/inotifywait"
    CID_MAP="${cidMapFile}"

    touch "$CID_MAP"
    ${pkgs.coreutils}/bin/chmod 0644 "$CID_MAP"

    log() {
      echo "[$(date -Iseconds)] $*"
    }

    add_file() {
      local path="$1"
      [ -f "$path" ] || return 0
      case "$(basename "$path")" in
        .* | *.part | *.tmp | *.synced.* | *.aria2) return 0 ;;
      esac

      log "Adding $path"
      cid=$($IPFS add --nocopy --pin --quieter "$path" 2>/dev/null) || {
        log "Failed to add $path"
        return 0
      }
      log "Pinned $path -> $cid"
      ${pkgs.gnused}/bin/sed -i "\|^[^ ]* $path$|d" "$CID_MAP"
      echo "$cid $path" >> "$CID_MAP"
    }

    remove_file() {
      local path="$1"
      cid=$(${pkgs.gawk}/bin/awk -v p="$path" '$0 ~ p {print $1; exit}' "$CID_MAP")
      if [ -n "$cid" ]; then
        log "Unpinning $cid ($path)"
        $IPFS pin rm "$cid" 2>/dev/null || true
        ${pkgs.gnused}/bin/sed -i "\|^[^ ]* $path$|d" "$CID_MAP"
      else
        log "No CID found for removed file: $path"
      fi
    }

    # initial sync: pin any file in the watch dirs not already in cid-map
    log "Starting initial sync..."
    for dir in ${lib.escapeShellArgs watchDirs}; do
      if [ -d "$dir" ]; then
        ${pkgs.findutils}/bin/find "$dir" -type f | while read -r f; do
          if ! ${pkgs.gnugrep}/bin/grep -q " $f$" "$CID_MAP" 2>/dev/null; then
            add_file "$f"
          fi
        done
      fi
    done
    log "Initial sync complete"

    # clean stale entries: unpin files that no longer exist on disk
    log "Cleaning stale entries..."
    while IFS=' ' read -r cid path; do
      if [ ! -f "$path" ]; then
        log "Stale entry: $path (CID: $cid)"
        $IPFS pin rm "$cid" 2>/dev/null || true
        ${pkgs.gnused}/bin/sed -i "\|^[^ ]* $path$|d" "$CID_MAP"
      fi
    done < "$CID_MAP"
    log "Cleanup complete"

    # pin all files in a newly appeared directory (covers the inotify
    # recursive-watch race when a brand-new subdir is created + filled fast)
    scan_new_dir() {
      local dir="$1"
      log "Scanning new directory: $dir"
      ${pkgs.findutils}/bin/find "$dir" -type f | while read -r f; do
        add_file "$f"
      done
    }

    # watch for changes
    log "Watching directories: ${lib.concatStringsSep ", " watchDirs}"
    $INOTIFYWAIT -m -r --format $'%w\t%e\t%f' \
      -e close_write \
      -e moved_to \
      -e moved_from \
      -e delete \
      -e create \
      ${lib.escapeShellArgs watchDirs} |
    while IFS=$'\t' read -r dir event file; do
      path="''${dir}''${file}"
      case "$event" in
        CREATE,ISDIR*|MOVED_TO,ISDIR*)
          scan_new_dir "$path"
          ;;
        CLOSE_WRITE*|MOVED_TO*)
          add_file "$path"
          ;;
        DELETE*|MOVED_FROM*)
          remove_file "$path"
          ;;
      esac
    done
  '';

  uploadServer = pkgs.writers.writePython3Bin "ipfs-upload-server" {
    flakeIgnore = [ "E501" ];
  } ./ipfs_upload.py;

  # Periodic reconciliation so cid-map/pins stay in sync with the filesystem
  # even when the inotify watcher drops events:
  #   reverse - unpin + drop cid-map entries for files no longer on disk.
  #   forward - pin files present on disk but missing from cid-map. The watcher
  #             loop is single-threaded and blocks 1-2 min on each multi-GB
  #             `ipfs add`; while blocked, a concurrent upload's CREATE,ISDIR +
  #             MOVED_TO for a brand-new subdir can overflow the inotify queue
  #             and be dropped, leaving a fully-written file never pinned. The
  #             forward sweep heals that within an hour.
  reconcileScript = pkgs.writers.writeBash "ipfs-pin-reconcile" ''
    set -efu

    IPFS="${pkgs.kubo}/bin/ipfs"
    CID_MAP="${cidMapFile}"

    [ -f "$CID_MAP" ] || exit 0

    # Reverse: rebuild cid-map, unpinning entries whose file is gone. One pass
    # avoids sed regex issues with special chars like [ ] in paths. Small race
    # with the watcher's concurrent appends -- a line written during this loop
    # may be lost, but is re-added on the next inotify event or watcher restart.
    tmp=$(${pkgs.coreutils}/bin/mktemp)
    removed=0
    while IFS=' ' read -r cid path; do
      [ -n "$cid" ] || continue
      if [ -e "$path" ]; then
        echo "$cid $path" >> "$tmp"
      else
        $IPFS pin rm "$cid" >/dev/null 2>&1 || true
        removed=$((removed + 1))
      fi
    done < "$CID_MAP"

    if [ "$removed" -gt 0 ]; then
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv "$tmp" "$CID_MAP"
      echo "reconciled: removed $removed stale entries"
    else
      ${pkgs.coreutils}/bin/rm -f "$tmp"
    fi

    # Forward: pin on-disk files missing from cid-map. Only files older than
    # 10 min -- a file that old and still absent from cid-map was dropped by the
    # watcher, not in-flight. No lock against the watcher: concurrent
    # `add --nocopy` of the same file is idempotent (verified), so a rare
    # double-add is harmless.
    for dir in ${lib.escapeShellArgs watchDirs}; do
      [ -d "$dir" ] || continue
      ${pkgs.findutils}/bin/find "$dir" -type f -mmin +10 | while read -r f; do
        case "$(${pkgs.coreutils}/bin/basename "$f")" in
          .* | *.part | *.tmp | *.synced.* | *.aria2) continue ;;
        esac
        if ${pkgs.gnugrep}/bin/grep -q " $f$" "$CID_MAP" 2>/dev/null; then
          continue
        fi
        cid=$($IPFS add --nocopy --pin --quieter "$f" 2>/dev/null) || {
          echo "reconcile: failed to add $f"
          continue
        }
        echo "$cid $f" >> "$CID_MAP"
        echo "reconcile: pinned missed file $f -> $cid"
      done
    done
  '';
in
{
  lass.ports = {
    "5001" = "kubo-api";
    "8089" = "kubo-gateway";
    "8090" = "ipfs-upload";
  }
  // lib.genAttrs (lib.unique (
    # "/ip4/0.0.0.0/udp/4001/quic-v1" -> "4001", nixpkgs' default Swarm addresses
    map (addr: lib.elemAt (lib.splitString "/" addr) 4) config.services.kubo.settings.Addresses.Swarm
  )) (_: "kubo-swarm");

  # symlink /var/download into IPFS root so --nocopy works
  systemd.tmpfiles.rules = [
    "L+ /var/lib/ipfs/download - - - - /var/download"
    # Staging area for ipfs-upload: same filesystem as the destination, but
    # outside the pin-watcher's watch dirs (movies/shows/games) so inotify
    # never fires on in-flight uploads.
    "d /var/download/incoming 0755 ${config.services.kubo.user} ${config.services.kubo.group} -"
    "d /var/download/incoming/uploader 0755 ${config.services.kubo.user} ${config.services.kubo.group} -"
    # Let the ipfs-upload service write into /var/download/games. Owner
    # = ipfs so the service has write; group = users + setgid so existing
    # CLI users (lass) keep write via group and new uploads inherit
    # group=users.
    "z /var/download/games 2775 ${config.services.kubo.user} users -"
  ];

  services.kubo = {
    enable = true;
    settings = {
      # kubo 0.40 deprecated Reprovider in favor of Provide; the nixpkgs
      # module still injects a default Reprovider block, so null it out
      # explicitly or kubo refuses to start.
      Reprovider = null;
      Experimental.FilestoreEnabled = true;
      Addresses = {
        API = [
          "/ip4/127.0.0.1/tcp/${toString config.lass.servicePorts.kubo-api}"
          "/ip6/::1/tcp/${toString config.lass.servicePorts.kubo-api}"
        ];
        Gateway = [
          "/ip4/0.0.0.0/tcp/${toString config.lass.servicePorts.kubo-gateway}"
          "/ip6/::/tcp/${toString config.lass.servicePorts.kubo-gateway}"
        ];
      };
      Datastore.StorageMax = "100GB";
      # limit bandwidth: 5MB/s out, 5MB/s in
      Swarm.ConnMgr = {
        LowWater = 100;
        HighWater = 400;
        GracePeriod = "20s";
      };
      Swarm.Transports.Network.TCP = true;
      Swarm.Transports.Network.QUIC = true;
      Swarm.ResourceMgr = {
        Enabled = true;
        MaxMemory = "2GB";
      };
      # disable relay to reduce overhead
      Swarm.RelayClient.Enabled = false;
      Swarm.RelayService.Enabled = false;
      # autoclient: DHT client (no server queries) + IPNI/cid.contact HTTP
      # announcements. Content is discoverable by both DHT peers and lassie
      # (which uses IPNI for provider discovery).
      Routing.Type = "autoclient";
      Provide = {
        Strategy = "pinned";
        DHT.Interval = "12h";
      };
    };
  };

  # kubo takes 70s+ to shut down gracefully (longer the longer it ran). A
  # changed ipfs unit is restarted in switch-to-configuration's start phase
  # instead of stopped up front, so the other changed units don't stay down
  # for the whole stop phase waiting on it.
  systemd.services.ipfs.stopIfChanged = false;

  boot.kernel.sysctl."fs.inotify.max_user_watches" = 1048576;

  systemd.services.ipfs-pin-watcher = {
    description = "Auto-pin files to IPFS using inotify";
    after = [ "ipfs.service" ];
    requires = [ "ipfs.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Environment = [ "IPFS_PATH=/var/lib/ipfs" ];
      ExecStart = pinWatcherScript;
      Restart = "always";
      RestartSec = "10s";
      User = config.services.kubo.user;
      Group = config.services.kubo.group;
      SupplementaryGroups = [ "radio_container" ];
    };
  };

  systemd.services.ipfs-upload = {
    description = "HTTP upload endpoint that writes files under /var/lib/ipfs/download and pins them";
    after = [ "ipfs.service" ];
    requires = [ "ipfs.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Environment = [
        "IPFS_PATH=/var/lib/ipfs"
        "IPFS_BIN=${pkgs.kubo}/bin/ipfs"
        "DOWNLOAD_ROOT=/var/lib/ipfs/download"
        "BIND=127.0.0.1"
        "PORT=${toString config.lass.servicePorts.ipfs-upload}"
      ];
      ExecStart = "${uploadServer}/bin/ipfs-upload-server";
      Restart = "always";
      RestartSec = "10s";
      User = config.services.kubo.user;
      Group = config.services.kubo.group;
      # /var/download is owned by ipfs:ipfs on neoprism, so no extra
      # groups needed. Existing subdirs owned by other users (e.g. games
      # → lass:users) are not writable by this service; uploads to those
      # paths will get a 500 unless ownership is adjusted out-of-band.
    };
  };

  systemd.services.ipfs-pin-reconcile = {
    description = "Reconcile pins / cid-map against the filesystem";
    after = [ "ipfs.service" ];
    requires = [ "ipfs.service" ];
    serviceConfig = {
      Type = "oneshot";
      Environment = [ "IPFS_PATH=/var/lib/ipfs" ];
      ExecStart = reconcileScript;
      User = config.services.kubo.user;
      Group = config.services.kubo.group;
    };
  };

  systemd.timers.ipfs-pin-reconcile = {
    description = "Reconcile pins / cid-map hourly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "1h";
      Unit = "ipfs-pin-reconcile.service";
    };
  };

  networking.firewall.allowedTCPPorts = [
    config.lass.servicePorts.kubo-swarm
    config.lass.servicePorts.kubo-gateway
  ];
  networking.firewall.allowedUDPPorts = [
    config.lass.servicePorts.kubo-swarm # QUIC
  ];

  # Shadow `ipfs` in PATH with a wrapper that rejects `ipfs add` without
  # --nocopy. The kubo daemon and pin-watcher use absolute store paths, so
  # they are unaffected. This blocks confused agents/users from creating
  # blockstore-only duplicates of files that already live in
  # /var/lib/ipfs/download.
  environment.systemPackages = [
    (lib.hiPrio (
      pkgs.writeShellScriptBin "ipfs" ''
        if [ "''${1-}" = "add" ]; then
          for a in "$@"; do
            case "$a" in
              --nocopy|--nocopy=true) exec ${pkgs.kubo}/bin/ipfs "$@" ;;
            esac
          done
          echo "refused: 'ipfs add' without --nocopy is forbidden on this host." >&2
          echo "         Use 'ipfs add --nocopy <path>' so the file is referenced via filestore" >&2
          echo "         instead of duplicated into the blockstore." >&2
          exit 1
        fi
        exec ${pkgs.kubo}/bin/ipfs "$@"
      ''
    ))
  ];
}
