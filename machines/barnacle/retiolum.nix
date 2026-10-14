{
  self,
  config,
  pkgs,
  lib,
  ...
}:

# Retiolum node on nix-darwin. tincr's own darwin module does the launchd
# plumbing; the daemon is the same pkgs/tincr the NixOS machines run (they
# use nixpkgs' services.tinc, see configs/retiolum.nix). kartei is only the
# host database here, same as on NixOS — its darwin retiolum shim would
# pull tincd from kartei's own tincr pin instead.
let
  net = "retiolum";
  name = config.networking.hostName;
  vars = config.clan.core.vars.generators.${net};

  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  own = kartei.own.${name};
in
{
  imports = [ self.inputs.tincr.darwinModules.tincr ];

  services.tincr.package = self.packages.${pkgs.system}.tincr;

  services.tincr.networks.${net} = {
    nodeName = name;
    listenPort = 655;
    ed25519PrivateKeyFile = vars.files."${net}.ed25519_key.priv".path;
    hosts = kartei.tincHosts;
    # eve/eva/ni/prism: the krebs hubs kartei's shim dialled. A laptop
    # behind NAT also needs relays we control; same list as the NixOS
    # nodes in configs/retiolum.nix, plus starkstrom.
    connectTo = [
      "eve"
      "eva"
      "ni"
      "prism"
      "neoprism"
      "starkstrom"
    ];
    addresses = lib.optional (own.ip4 != null) "${own.ip4}/12" ++ [ "${own.ip6}/16" ];
    extraConfig = ''
      LocalDiscovery = yes
      Broadcast = no
    '';
  };

  # No resolved on Darwin, so the tincr DNS stub cannot be routed
  # per-suffix; keep a static hosts block, replaced in place on every
  # darwin-rebuild via BEGIN/END markers.
  system.activationScripts.postActivation.text =
    let
      hostsFile = if own.ip4 == null then kartei.extraHosts.v6only else kartei.extraHosts.v4v6;
    in
    lib.mkAfter ''
      tmp=$(mktemp /private/etc/hosts.XXXXXX)
      chmod 644 "$tmp"
      awk '
        /^# BEGIN RETIOLUM HOSTS$/ { skip=1; next }
        /^# END RETIOLUM HOSTS$/   { skip=0; next }
        !skip { print }
      ' /private/etc/hosts > "$tmp"
      {
        echo "# BEGIN RETIOLUM HOSTS"
        cat ${builtins.toFile "retiolum-hosts" hostsFile}
        echo "# END RETIOLUM HOSTS"
      } >> "$tmp"
      mv "$tmp" /private/etc/hosts
    '';

  # Same generator as configs/retiolum.nix, minus the RSA half: tincr is
  # SPTPS/Ed25519-only and kartei no longer wants an rsa.key.
  #
  # neededFor = "activation" because clan's /run/secrets installer is
  # Linux-only (tmpfs + move-mount), so on darwin the key is deployed as a
  # plain file below clan.core.vars.password-store.secretLocation.
  #
  # The public half is published in kartei as
  # lass/hosts/barnacle/retiolum/ed25519.key; keep this script stable or the
  # regenerated key will no longer match that card.
  clan.core.vars.generators.${net} = {
    files."${net}.ed25519_key.priv".neededFor = "activation";
    files."${net}.ed25519_key.pub".secret = false;
    runtimeInputs = [
      pkgs.coreutils
      self.packages.${pkgs.system}.tincr
    ];
    # generate-ed25519-keys wants a Name in tinc.conf and writes the pubkey as
    # a ready-made `Ed25519PublicKey = ...` line into hosts/$Name.
    script = ''
      mkdir -p "$out/hosts"
      echo 'Name = ${name}' >"$out/tinc.conf"
      tinc --config "$out" generate-ed25519-keys
      mv "$out/ed25519_key.priv" "$out/${net}.ed25519_key.priv"
      mv "$out/hosts/${name}" "$out/${net}.ed25519_key.pub"
      rm -r "$out/tinc.conf" "$out/hosts"
    '';
  };
}
