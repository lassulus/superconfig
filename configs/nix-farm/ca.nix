{ pkgs, ... }:
# Private CA of the build farm plus the client cert lass uses towards it.
# Shared, so every machine importing this sees the same CA. Clan requires a
# shared generator to be defined identically on all machines, so nothing is
# deployed from here: per-machine generators (nix-farm-server in builder.nix,
# nix-farm-client in client.nix) depend on it and copy out the files they
# need with their own owner/mode. The certs are not secret, but as secret
# files their paths are known before `clan vars generate` ran, so the configs
# still evaluate until then.
{
  clan.core.vars.generators.nix-farm-ca = {
    share = true;
    files."ca.key".deploy = false;
    files."ca.crt".deploy = false;
    files."client.key".deploy = false;
    files."client.crt".deploy = false;
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$out/ca.key" -out "$out/ca.crt" -days 3650 \
        -subj "/CN=nix-farm-ca" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$out/client.key" -out client.csr -subj "/CN=lass"
      printf '%s\n' \
        "basicConstraints=critical,CA:FALSE" \
        "keyUsage=critical,digitalSignature" \
        "extendedKeyUsage=clientAuth" > client.ext
      openssl x509 -req -in client.csr -CA "$out/ca.crt" -CAkey "$out/ca.key" \
        -CAcreateserial -days 3650 -extfile client.ext -out "$out/client.crt"
    '';
  };
}
