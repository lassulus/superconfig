{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  continuum = self.packages.${pkgs.stdenv.hostPlatform.system}.continuum;
  vars = config.clan.core.vars.generators;
  stateDirectory = "continuum";
  stateDir = "/var/lib/${stateDirectory}";

  # a host adds config files as credentials named *.json; continuum lets later ones win
  extraConfigs = lib.filter (lib.hasSuffix ".json") (
    map (credential: lib.head (lib.splitString ":" credential)) (
      lib.toList config.systemd.services.continuum.serviceConfig.LoadCredential
    )
  );

  storeRoot = pkgs.runCommand "continuum-root" { } ''
    ${lib.getExe' continuum "continuum-party"} root ${./first.json} > $out
  '';

  settings = (pkgs.formats.json { }).generate "continuum.json" {
    bind-addr = "127.0.0.1:${toString config.lass.servicePorts.continuum}";
    htpasswd = "\${env:CREDENTIALS_DIRECTORY}/htpasswd";
    node-key-file = "\${env:CREDENTIALS_DIRECTORY}/node.key";
    state-file = "${stateDir}/state.json";
    document-file = "${stateDir}/document.automerge";
    store-file = "${stateDir}/store.json";
    store-root = storeRoot;
    store-party = "lass";
    # shown next to the node ID in /peers and the dashboard
    alias = config.networking.hostName;
    # nodes to join through, by their onion services: tv's, coaxmetal's, atlas', styx', ignavia's, neoprism's
    seeds = [
      "tor:ggktase65blt4plqinsqpx5xfykrlba7pejcrtssxantmkxrtyfzdoid.onion:9662"
      "tor:krydkcoqjsfgc7mdse4vlqyg6s5lfa24t7mtj6huowwkcqsc3xu4n2yd.onion:9662"
      "tor:4ddulvy3yas5ksi4xw2qwgtwcug2o6ojdz3742kow6apx6ujv2w77lqd.onion:9662"
      "tor:6pplml2rjn6pa27nusgznlnx2zuifdjv46bq4suihwzehifgzggtc5ad.onion:9662"
      "tor:c3ntxfuxjqjltmoysiedslnx2zsnons55cegdzdksyx3qxd4fsrsz7yd.onion:9662"
      "tor:76ibh3yw2d6adrtfgayue2qp7orhetgrldbl5wpjfd3mdgckmmlbfsad.onion:9662"
    ];
    tor = {
      enable = true;
      state-dir = "${stateDir}/tor";
    };
  };
in
{
  lass.ports."3030" = "continuum";

  clan.core.vars.generators.continuum = {
    files."node.key" = { };
    files."node-id".secret = false;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    # node.key is the raw Ed25519 seed, node-id the hex of its public key
    script = ''
      head -c 32 /dev/urandom > "$out/node.key"
      pub=$(
        { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'; cat "$out/node.key"; } |
          openssl pkey -inform DER -pubout -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n'
      )
      printf 'continuum:%s' "$pub" > "$out/node-id"
    '';
  };

  clan.core.vars.generators.continuum-api = {
    files.password = { };
    files.htpasswd = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.libargon2
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/password"
      argon2 "$(openssl rand -hex 16)" -id -e < "$out/password" | sed 's/^/lass:/' > "$out/htpasswd"
    '';
  };

  systemd.services.continuum = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      # a list: merging serviceConfig must not force the command, which reads LoadCredential
      ExecStart = [
        (
          "${lib.getExe continuum} --config ${settings}"
          + lib.concatMapStrings (name: " --config %d/${name}") extraConfigs
        )
      ];
      DynamicUser = true;
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0700";
      LoadCredential = [
        "node.key:${vars.continuum.files."node.key".path}"
        "htpasswd:${vars.continuum-api.files.htpasswd.path}"
      ];
      Restart = "always";
      RestartSec = 5;
    };
  };

  # DynamicUser keeps the state under /var/lib/private
  lass.backup.state.continuum.folders = [ "/var/lib/private/${stateDirectory}" ];
}
