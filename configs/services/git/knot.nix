{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  domain = "knot.lassul.us";
  # DID of the owner's account on pds.lassul.us
  ownerDid = "did:plc:6nk6tk76up7254wawocoekjr"; # lass.pds.lassul.us
  user = "tangled-knot";
  stateDir = "/var/lib/tangled-knot";
  listenAddr = "127.0.0.1:5555";
  sshPort = 2222;
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.tangled.knot-rs;

  # `knot-server config-template` lists the keys; upstream's defaults, except
  # where commented
  rendered = (pkgs.formats.toml { }).generate "knot.toml" {
    server = {
      hostname = domain;
      admins = [ ownerDid ];
      appview_endpoint = "https://git.lassul.us";
      listen_addr = listenAddr;
      internal_listen_addr = "[::1]:5444";
      ssh_listen_addr = "[::]:${toString sshPort}";
      ssh_host_key_file = "${stateDir}/ssh_host_key";
    };
    atproto.plc_directory = "https://plc.directory";
    acl.admission = "closed";
    repo.scan_path = "${stateDir}/repos";
    # sha256 repos can't exchange objects with sha1 ones (github, cgit)
    git.object_format = "sha1";
    secrets = {
      sealed_key_file = "${stateDir}/sealed-keys";
      master_key_env = "KNOT_MASTER_KEY";
    };
    tls = {
      http3 = true;
      acme_enabled = false;
      acme_cache_dir = "${stateDir}/acme";
      acme_staging = false;
      mtls_enabled = false;
    };
    xrpc = {
      trusted_proxy_header = "x-forwarded-for";
      trusted_proxies = [
        "127.0.0.1"
        "::1"
      ];
    };
  };
  configFile = pkgs.runCommandLocal "knot-config.toml" { nativeBuildInputs = [ package ]; } ''
    knot-server validate --config-only ${rendered}
    ln -s ${rendered} $out
  '';
in
{
  # Tangled knot 2 (knot-rs): git hosting for git.lassul.us, following
  # tangled's nix/modules/knot-rs.nix without its flake (the module files are
  # in a fetched source, importing them would be IFD): plain HTTP behind
  # nginx, unprivileged ports, keys in stateDir. The Go knot's unit and user
  # are both named knot, which the DNS server already uses.
  # Knot 2 serves ssh itself on [::]:2222 (it binds a single address, and
  # sshd keeps 22). Port 22 on the public addresses is redirected to it, so
  # git@knot.lassul.us:<owner>/<repo> works as the appview shows it. Admin
  # ssh stays on 22 via retiolum/wiregrill and on public 45621
  # (ssh-redirect.nix).

  clan.core.vars.generators.tangled-knot = {
    files."knot.env" = { };
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      echo "KNOT_MASTER_KEY=$(openssl rand -base64 32)" > "$out/knot.env"
    '';
  };

  environment.systemPackages = [ package ];
  environment.etc."knot/config.toml".source = configFile;

  users.users.${user} = {
    isSystemUser = true;
    home = stateDir;
    group = user;
  };
  users.groups.${user} = { };

  systemd.tmpfiles.settings."10-knot-rs" = {
    ${stateDir}.d = {
      mode = "0750";
      inherit user;
      group = user;
    };
    "${stateDir}/repos".d = {
      mode = "0750";
      inherit user;
      group = user;
    };
  };

  systemd.services.knot-rs = {
    description = "knot git server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ configFile ];
    startLimitIntervalSec = 60;
    startLimitBurst = 5;
    serviceConfig = {
      User = user;
      Group = user;
      UMask = "0077";
      WorkingDirectory = stateDir;
      EnvironmentFile = config.clan.core.vars.generators.tangled-knot.files."knot.env".path;
      ExecStart = "${lib.getExe package} /etc/knot/config.toml";
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 120;
      LimitNOFILE = 65536;
      CapabilityBoundingSet = [ ];
      ReadWritePaths = [
        stateDir
        "${stateDir}/repos"
      ];
      NoNewPrivileges = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateUsers = true;
      ProtectHostname = true;
      ProtectClock = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      PrivateMounts = true;
      SystemCallFilter = [
        "@system-service"
        "~@privileged @resources"
      ];
      SystemCallArchitectures = "native";
    };
  };

  networking.firewall.allowedTCPPorts = [ sshPort ];

  # knot 2 doesn't request crawls (no KNOT_MIRRORS), so subscribe our
  # mirror (knotmirror.nix) to the knot's event stream whenever either
  # starts; the mirror marks a knot offline after it was unreachable for a
  # while
  systemd.services.knotmirror-request-crawl = {
    wantedBy = [
      "knot-rs.service"
      "knotmirror.service"
    ];
    after = [
      "knot-rs.service"
      "knotmirror.service"
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.curl}/bin/curl -fsS --retry 10 --retry-connrefused \
        -H 'Content-Type: application/json' -d '{"hostname":"${domain}"}' \
        http://127.0.0.1:7000/xrpc/sh.tangled.sync.requestCrawl
    '';
  };

  networking.nftables.tables.knot-ssh = {
    family = "inet";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip daddr 95.217.192.59 tcp dport 22 redirect to :${toString sshPort}
        ip6 daddr 2a01:4f9:4a:4f1a::2 tcp dport 22 redirect to :${toString sshPort}
      }
    '';
  };

  # repos (with the ACL data), sealed keys and ssh host key; the master key
  # is in vars
  lass.backup.state.tangled-knot.folders = [ stateDir ];

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://${listenAddr}";
      recommendedProxySettings = true;
      # /events
      proxyWebsockets = true;
      extraConfig = ''
        proxy_read_timeout 1d;
        client_max_body_size 0;
        proxy_request_buffering off;
      '';
    };
  };
}
