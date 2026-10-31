{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  # nixpkgs marks radicle-node insecure: private repos are not encrypted
  # between nodes. Clear the flag on the package we use instead of allowing
  # it globally.
  radicle-node = self.lib.secureify pkgs.radicle-node;
in
{
  lass.ports = {
    "8776" = "radicle-node";
    "8778" = "radicle-httpd";
  };

  # Generate Radicle identity keys using clan vars
  clan.core.vars.generators.radicle = {
    files."radicle.key" = { };
    files."radicle.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "radicle" -f "$out/radicle.key"
      mv "$out/radicle.key.pub" "$out/radicle.pub"
    '';
  };

  services.radicle = {
    enable = true;
    package = radicle-node;
    # The module's checkConfig runs `rad config` from
    # pkgs.buildPackages.radicle-node, not cfg.package, which trips the
    # insecure check. Same validation, against our package.
    configFile = lib.mkForce (
      pkgs.runCommand "config.json"
        {
          nativeBuildInputs = [ (self.lib.secureify pkgs.buildPackages.radicle-node) ];
          json = builtins.toJSON config.services.radicle.settings;
          passAsFile = [ "json" ];
          preferLocalBuild = true;
        }
        ''
          install -D -m 644 "$jsonPath" $out
          ln -s $out config.json
          install -D -m 644 /dev/stdin keys/radicle.pub <<<"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBgFMhajUng+Rjj/sCFXI9PzG8BQjru2n7JgUVF1Kbv5 snakeoil"
          RAD_HOME=$PWD rad config >/dev/null
        ''
    );
    privateKey = config.clan.core.vars.generators.radicle.files."radicle.key".path;
    publicKey = config.clan.core.vars.generators.radicle.files."radicle.pub".path;

    node.openFirewall = true;

    httpd = {
      enable = true;
      # The default 8080 is taken on neoprism by jitsi-videobridge's REST
      # API (Jetty, 127.0.0.1:8080): radicle-httpd died with "Address
      # already in use" on every restart and nginx proxied
      # radicle.lassul.us to Jetty's 404 page instead.
      listenPort = config.lass.servicePorts.radicle-httpd;
      nginx = {
        serverName = "radicle.lassul.us";
        enableACME = true;
        forceSSL = true;
      };
    };

    settings = {
      publicExplorer = "https://app.radicle.xyz/nodes/$host/$rid$path";
      preferredSeeds = [
        "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@seed.radicle.xyz:8776"
        "z6Mkmqogy2qEM2ummccUthFEaaHvyYmYBYh3dbe9W4ebScxo@iris.radicle.network:8776"
      ];
      web.pinned.repositories = [ ];
      cli.hints = true;
      node = {
        alias = config.networking.hostName;
        listen = [ "0.0.0.0:${toString config.lass.servicePorts.radicle-node}" ];
        peers.type = "dynamic";
        connect = [ ];
        externalAddresses = [ "radicle.lassul.us:${toString config.lass.servicePorts.radicle-node}" ];
        network = "main";
        log = "INFO";
        relay = "auto";
        limits = {
          routingMaxSize = 1000;
          routingMaxAge = 604800;
          gossipMaxAge = 1209600;
          fetchConcurrency = 1;
          maxOpenFiles = 4096;
          rate = {
            inbound = {
              fillRate = 5.0;
              capacity = 1024;
            };
            outbound = {
              fillRate = 10.0;
              capacity = 2048;
            };
          };
          connection = {
            inbound = 128;
            outbound = 16;
          };
          fetchPackReceive = "500.0 MiB";
        };
        workers = 8;
        seedingPolicy = {
          default = "allow";
          scope = "all";
        };
      };
    };
  };
}
