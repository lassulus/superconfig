{
  config,
  pkgs,
  ...
}:
let
  api = "/ip4/127.0.0.1/tcp/${toString config.lass.servicePorts.kubo-api}";
  ipfs = "${pkgs.kubo}/bin/ipfs";
  uploadServer = pkgs.writers.writePython3Bin "ipfs-upload-server" {
    flakeIgnore = [ "E501" ];
  } ./ipfs_upload.py;
in
{
  imports = [ ../../configs/nginx.nix ];

  lass.ports."8090" = "ipfs-upload";

  # scratch area for in-flight uploads (extracted, added, then deleted)
  systemd.tmpfiles.rules = [
    "d /var/lib/ipfs/incoming 0700 ${config.services.kubo.user} ${config.services.kubo.group} -"
  ];

  # anonymous tarball -> `ipfs add` (into the blockstore) -> pinned -> returns CID
  systemd.services.ipfs-upload = {
    description = "Anonymous tarball -> IPFS pinning endpoint";
    after = [ "ipfs.service" ];
    requires = [ "ipfs.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Environment = [
        "IPFS_BIN=${pkgs.kubo}/bin/ipfs"
        "IPFS_API=${api}"
        "STAGING=/var/lib/ipfs/incoming"
        "ROOTS_FILE=/var/lib/ipfs/gc-roots"
        "GATEWAY_BASE=https://starkstrom.lassul.us"
        "BIND=127.0.0.1"
        "PORT=${toString config.lass.servicePorts.ipfs-upload}"
        "MAX_BYTES=8589934592" # 8 GiB compressed upload
        "MAX_EXTRACT_BYTES=21474836480" # 20 GiB extracted
        "DISK_PATH=/var/lib/ipfs"
        "MIN_FREE_BYTES=322122547200" # refuse uploads with <300 GiB free
      ];
      ExecStart = "${uploadServer}/bin/ipfs-upload-server";
      Restart = "always";
      RestartSec = "10s";
      User = config.services.kubo.user;
      Group = config.services.kubo.group;
    };
  };

  # public vhost (starkstrom's own name): writable upload at /, read-only gateway at /ipfs/
  services.nginx.virtualHosts."starkstrom.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/ipfs/".extraConfig = ''
      proxy_pass http://127.0.0.1:${toString config.lass.servicePorts.kubo-gateway};
      proxy_set_header Host $host;
    '';
    locations."/".extraConfig = ''
      proxy_pass http://127.0.0.1:${toString config.lass.servicePorts.ipfs-upload};
      client_max_body_size 8g;
      # Stream multi-GB bodies straight through instead of spooling to disk.
      proxy_request_buffering off;
      # With unbuffered proxying over HTTP/2, nginx sizes the per-stream flow
      # control window to max(client_body_buffer_size, http2_body_preread_size)
      # (ngx_http_v2_read_request_body). The 64 KiB default capped uploads at
      # 64 KiB / RTT (~1.2 MB/s at 55 ms) whenever the backend read slower than
      # the client sent. 8 MiB in-flight per upload lifts the ceiling to
      # ~150 MB/s at that RTT.
      client_body_buffer_size 8m;
      # The backend hashes/pins for minutes before answering.
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    '';
  };

  # Explicit GC + gc-root management. Pins are the GC roots (persisted by kubo);
  # `ipfs-gc` reclaims everything not reachable from a pin. Prune first with
  # `ipfs-roots rm <cid>`, then `ipfs-gc`.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "ipfs-gc" ''
      exec ${ipfs} --api ${api} repo gc "$@"
    '')
    (pkgs.writeShellScriptBin "ipfs-roots" ''
      cmd="''${1-list}"
      shift || true
      case "$cmd" in
        list) exec ${ipfs} --api ${api} pin ls --type=recursive ;;
        ledger) exec ${pkgs.coreutils}/bin/cat /var/lib/ipfs/gc-roots ;;
        rm) exec ${ipfs} --api ${api} pin rm "$@" ;;
        *)
          echo "usage: ipfs-roots [list|ledger|rm <cid>...]" >&2
          exit 1
          ;;
      esac
    '')
  ];
}
