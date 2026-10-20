{
  self,
  config,
  pkgs,
  lib,
  ...
}:

let
  tincr = self.packages.${pkgs.system}.tincr;
  tincrPkg = pkgs.runCommand "tincr-sbin-${tincr.version}" { version = tincr.version; } ''
    mkdir -p $out
    cp -r ${tincr}/* $out/
    chmod -R u+w $out
    ln -s bin $out/sbin
  '';

  # Peer keys and addresses come straight from kartei. This is only the host
  # database -- the daemon stays on nixpkgs' services.tinc with pkgs/tincr
  # swapped in (barnacle does the same with tincr's darwin module, see
  # machines/barnacle/retiolum.nix).
  #
  # tincHosts is already filtered to SPTPS-capable nodes, so the RSA-only
  # leftovers tincr refuses per connection attempt are gone.
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };

  name = config.networking.hostName;
  own = kartei.own.${name};
in

{
  imports = [ ./monitoring/retiolum-ping.nix ];

  networking.firewall.allowedTCPPorts = [ 655 ];
  networking.firewall.allowedUDPPorts = [ 655 ];

  services.tinc.networks.retiolum = {
    package = tincrPkg;
    # 1+ maps to per-packet Debug/Trace in tincr, which floods journald
    # (tens of thousands of suppressed messages per minute) and rotates
    # all other units' logs out of the journal within hours
    debugLevel = 0;
    hosts = kartei.tincHosts;
    extraConfig = ''
      AutoConnect = yes
      LocalDiscovery = yes
    '';
    settings = {
      Interface = "retiolum";
      Name = name;
      ConnectTo = [
        "neoprism"
        "eve"
      ];
    };
  };

  # A changed tinc unit is restarted in switch-to-configuration's start phase
  # instead of stopped up front: otherwise retiolum stays down for the whole
  # stop phase (minutes when a unit like ipfs waits out its stop timeout) and
  # takes the deploying ssh session over <machine>.r with it.
  systemd.services."tinc.retiolum".stopIfChanged = false;

  # Warn and Error for every tinc* crate, plus Info for the per-event
  # targets: reachability (graph), meta connections (conn) and UDP path,
  # MTU and key-exchange changes (net). Their Debug/Trace and the other
  # targets' Info (autoconnect, auth, proto) stay off. Target-scoped on
  # purpose: `-d 0` sets the global directive and replaces a bare
  # RUST_LOG=warn, while `tinc` prefix-matches every tinc* crate's target.
  systemd.services."tinc.retiolum".environment.RUST_LOG =
    "tinc=warn,tincd::graph=info,tincd::conn=info,tincd::net=info";

  # Copy keys into the tinc config directory before tinc starts.
  # Running before nixpkgs' preStart ensures key generation is skipped.
  systemd.services."tinc.retiolum".preStart = lib.mkBefore ''
    rm -f /etc/tinc/retiolum/rsa_key.priv /etc/tinc/retiolum/ed25519_key.priv /etc/tinc/retiolum/tinc-up
    cp ${
      config.clan.core.vars.generators.retiolum.files."retiolum.rsa_key.priv".path
    } /etc/tinc/retiolum/rsa_key.priv
    cp ${
      config.clan.core.vars.generators.retiolum.files."retiolum.ed25519_key.priv".path
    } /etc/tinc/retiolum/ed25519_key.priv
    chown tinc-retiolum /etc/tinc/retiolum/rsa_key.priv /etc/tinc/retiolum/ed25519_key.priv
    chmod 600 /etc/tinc/retiolum/rsa_key.priv /etc/tinc/retiolum/ed25519_key.priv
  '';

  clan.core.vars.generators.retiolum = {
    files."retiolum.rsa_key.priv" = { };
    files."retiolum.ed25519_key.priv" = { };
    files."retiolum.rsa_key.pub".secret = false;
    files."retiolum.ed25519_key.pub".secret = false;
    runtimeInputs = with pkgs; [
      coreutils
      tinc_pre
    ];
    script = ''
      tinc --config "$out" generate-keys 4096 >/dev/null
      mv "$out"/rsa_key.priv "$out"/retiolum.rsa_key.priv
      mv "$out"/ed25519_key.priv "$out"/retiolum.ed25519_key.priv
      mv "$out"/rsa_key.pub "$out"/retiolum.rsa_key.pub
      mv "$out"/ed25519_key.pub "$out"/retiolum.ed25519_key.pub
    '';
  };

  systemd.network.networks.retiolum = {
    matchConfig.Name = "retiolum";
    address = lib.optional (own.ip4 != null) "${own.ip4}/16" ++ [ "${own.ip6}/16" ];
    linkConfig = {
      MTUBytes = "1377";
      RequiredForOnline = "no";
    };
    networkConfig = {
      LinkLocalAddressing = "no";
    };
  };

  environment.systemPackages = [
    tincrPkg
  ];

  # Upstream nixos/tinc preStart chowns hosts/ and invitations/ but not
  # the network dir itself, so tincr (and tinc 1.1pre18) can't persist
  # its address-cache there. Drop this once nixpkgs#520533 lands.
  systemd.tmpfiles.rules = [
    "z /etc/tinc/retiolum 0755 tinc-retiolum - -"
  ];
}
