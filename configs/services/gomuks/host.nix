# The gomuks backend (common.nix), reachable only from the proxy over
# retiolum. Other users run on this host, so the web password is the real
# protection: the vars generator below makes it; the password is not
# deployed, read it with `clan vars get styx gomuks/password`.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  common = import ./common.nix;
  port = config.lass.servicePorts.gomuks;
  stateDir = "/var/lib/private/gomuks";

  # gomuks fills in what is missing (token_key, VAPID keys, ...) and writes
  # config.yaml back, and asks for a password on stdin when there is none,
  # so the file stays mutable and preStart merges these keys into it
  settings = (pkgs.formats.json { }).generate "gomuks-settings.json" {
    web = {
      listen_address = "0.0.0.0:${toString port}";
      username = "lass";
      # websocket Origin hosts besides the request's own Host (path.Match)
      origin_patterns = [ common.domain ];
    };
    # the journal only, no colours; no log files under logs/
    logging.writers = [
      {
        type = "stdout";
        format = "pretty";
      }
    ];
  };
in
{
  lass.ports.${toString common.port} = "gomuks";

  clan.core.vars.generators.gomuks = {
    files.password.deploy = false;
    files.password-hash = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.mkpasswd
      pkgs.openssl
    ];
    # Go's x/crypto/bcrypt takes the $2b$ prefix; cost as gomuks' own prompt
    script = ''
      openssl rand -hex 16 | tr -d '\n' > "$out/password"
      mkpasswd -m bcrypt -R 12 -s < "$out/password" | tr -d '\n' > "$out/password-hash"
    '';
  };

  systemd.services.gomuks = {
    description = "gomuks web, a Matrix client (${common.domain})";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.GOMUKS_ROOT = "%S/gomuks";
    path = [ pkgs.yq-go ];
    preStart = ''
      mkdir -p "$STATE_DIRECTORY/config"
      config="$STATE_DIRECTORY/config/config.yaml"
      touch "$config"
      chmod 600 "$config"
      yq -i '
        . * load("${settings}")
        | .web.password_hash = (load_str(strenv(CREDENTIALS_DIRECTORY) + "/password-hash") | trim)
      ' "$config"
    '';
    serviceConfig = {
      # web-unifiedpush.patch: lets the Android app register a Web Push
      # (UnifiedPush) endpoint instead of an FCM token; not upstream yet
      ExecStart = lib.getExe (
        pkgs.gomuks-web.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./web-unifiedpush.patch ];
        })
      );
      DynamicUser = true;
      StateDirectory = "gomuks";
      StateDirectoryMode = "0700";
      LoadCredential = [
        "password-hash:${config.clan.core.vars.generators.gomuks.files.password-hash.path}"
      ];
      Restart = "always";
      RestartSec = 5;
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
      UMask = "0077";
    };
  };

  # the backend only for nginx on the proxy
  networking.firewall.extraInputRules = ''
    iifname "retiolum" ip saddr ${
      self.inputs.kartei.hosts.${common.proxy}.nets.retiolum.ip4.addr
    } tcp dport ${toString port} accept
  '';

  # data/ holds the Matrix session and its crypto keys; the database is
  # dumped consistently instead of copied, caches and logs are left out
  lass.backup.state.gomuks = {
    folders = [ stateDir ];
    exclude = [
      "${stateDir}/cache"
      "${stateDir}/logs"
      "${stateDir}/data/gomuks.db*"
    ];
    preBackup = ''
      ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" ${stateDir}/data/gomuks.db ".backup /var/backup/gomuks.db"
    '';
    # WAL-mode SQLite readers need to write the -shm file
    readWritePaths = [ "${stateDir}/data" ];
  };
}
