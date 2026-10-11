{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  vars = config.clan.core.vars.generators;
  cachePub = self + "/vars/per-machine/neoprism/nix-cache-signing/key.pub/value";
  credDir = "/run/credentials/nix-grpc-daemon.service";
in
{
  imports = [
    self.inputs.nix-grpc-store.nixosModules.server
    ./ca.nix
  ];

  # Server cert for the daemon, signed by the shared farm CA, plus a copy of
  # the CA cert to verify clients against. Secret files for the same reason
  # as in ca.nix. Root-owned: the daemon gets them via LoadCredential below.
  clan.core.vars.generators.nix-farm-server = {
    dependencies = [ "nix-farm-ca" ];
    files."server.key" = { };
    files."server.crt" = { };
    files."ca.crt" = { };
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$out/server.key" -out server.csr -subj "/CN=neoprism"
      printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature" \
        "extendedKeyUsage=serverAuth" \
        "subjectAltName=DNS:neoprism.r,DNS:neoprism.lassul.us" > server.ext
      openssl x509 -req -in server.csr \
        -CA "$in/nix-farm-ca/ca.crt" -CAkey "$in/nix-farm-ca/ca.key" \
        -CAcreateserial -days 3650 -extfile server.ext -out "$out/server.crt"
      cp "$in/nix-farm-ca/ca.crt" "$out/ca.crt"
    '';
  };

  # Standalone node: schedules onto itself, publishes outputs to niks3.
  services.nix-grpc-daemon = {
    enable = true;
    roles = [
      "builder"
      "scheduler"
    ];
    listen = "[::]:50051";
    # gRPC's cert file watcher treats mtime 0 as a stat failure and never
    # loads the key pair, and clan unpacks /run/secrets with mtime 0. systemd
    # credentials are fresh copies with a real mtime.
    tls = {
      certFile = "${credDir}/server.crt";
      keyFile = "${credDir}/server.key";
      clientCaFile = "${credDir}/ca.crt";
    };
    # `nix build --store grpc://… --eval-store auto` needs write (README).
    accessRules = [
      {
        cn = "lass";
        role = "write";
      }
    ];
    niks3 = {
      package = self.inputs.niks3.packages.${pkgs.stdenv.hostPlatform.system}.niks3;
      # same box, skip nginx/ACME
      url = "http://${config.services.niks3.httpAddr}";
      tokenFile = vars.niks3.files."api-token-grpc".path;
      cacheUrl = config.services.niks3.cacheUrl;
      # empty until `clan vars generate neoprism` wrote the key
      publicKeys = lib.optional (builtins.pathExists cachePub) (
        lib.removeSuffix "\n" (builtins.readFile cachePub)
      );
    };
  };

  systemd.services.nix-grpc-daemon.serviceConfig = {
    LoadCredential = map (f: "${f}:${vars.nix-farm-server.files.${f}.path}") [
      "server.crt"
      "server.key"
      "ca.crt"
    ];
    # Upstream's 2G default assumes the unit only proxies, but `niks3 push`
    # runs in this cgroup too and got OOM-killed on large NARs (kernel
    # modules), taking the whole daemon down with it.
    MemoryMax = "8G";
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ 50051 ];
}
