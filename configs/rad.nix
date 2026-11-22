{
  self,
  config,
  pkgs,
  ...
}:
# Per-machine Radicle identity and node for day-to-day development
# (rad clone/push/patch), as opposed to the public seed in ./radicle.lassul.us.nix.
#
# One radicle-node = one keypair = one Node ID; a node cannot serve several
# identities. So every machine gets its own key (generator `rad`) and hence
# its own DID, and repos that should accept pushes from all machines list each
# machine's DID as a delegate (`rad id update --delegate did:key:<nid>`).
#
# Radicle has no multi-user mode: the `rad` CLI and git-remote-rad write into
# the profile's storage themselves, signing with the key in keys/radicle. To
# make one identity usable by several accounts the profile lives outside any
# home, in /var/lib/rad, group-shared: the node runs as the `rad` system user,
# everything is setgid `rad` with group rwx, and the CLI/remote-helper wrappers
# below force umask 002 so files one side creates stay writable for the other.
# RAD_HOME points there for login shells; membership in `rad` is what grants
# use of the identity (mainUser is a member, add others per machine).
# Keys and config.json are symlinks into the clan vars secret dir / nix store,
# maintained by tmpfiles; storage and the control socket are ordinary state.
#
# The node only dials out (no listen address): the laptops sit behind NAT and
# the public seed neoprism relays for them, so nothing needs a port opened.
let
  # nixpkgs marks radicle-node insecure: private repos are not encrypted
  # between nodes. Clear the flag on the package we use instead of allowing
  # it globally.
  radicle-node = self.lib.secureify pkgs.radicle-node;
  generator = config.clan.core.vars.generators.rad;
  radHome = "/var/lib/rad";

  settings = {
    publicExplorer = "https://app.radicle.xyz/nodes/$host/$rid$path";
    preferredSeeds = [
      # our own seed (configs/radicle.lassul.us.nix on neoprism)
      "z6MkhTe9WWbqNdRAnWLHxL23gedRQWdhjajRbNAt5fCpae6o@radicle.lassul.us:8776"
      "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@seed.radicle.xyz:8776"
      # no iris.radicle.network: since 2026-11-20 it resets our sessions
      # every ~70 s and radicle-node 1.10.3 then spins its network thread
      # at 100 % CPU (confirmed on ignavia by blocking it)
    ];
    cli.hints = true;
    node = {
      alias = config.networking.hostName;
      listen = [ ];
      network = "main";
      log = "INFO";
      relay = "auto";
      # Only seed what this machine explicitly initialised, cloned or `rad seed`ed.
      seedingPolicy.default = "block";
    };
  };

  # Validate with `rad config` at build time (same trick as the nixpkgs seed
  # module) so a typo does not leave every machine's node crash-looping.
  configFile =
    pkgs.runCommand "rad-config.json"
      {
        nativeBuildInputs = [ (self.lib.secureify pkgs.buildPackages.radicle-node) ];
        json = builtins.toJSON settings;
        passAsFile = [ "json" ];
        preferLocalBuild = true;
      }
      ''
        install -D -m 644 "$jsonPath" $out
        ln -s $out config.json
        install -D -m 644 /dev/stdin keys/radicle.pub <<<"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBgFMhajUng+Rjj/sCFXI9PzG8BQjru2n7JgUVF1Kbv5 snakeoil"
        RAD_HOME=$PWD rad config >/dev/null
      '';

  # `rad` and `git-remote-rad` (what git runs for rad:// remotes) forced to
  # umask 002; first in the join so they shadow the plain radicle-node ones.
  wrap =
    bin:
    pkgs.writeShellScriptBin bin ''
      # ${radHome} is shared with the rad-node service via group rad.
      umask 002
      exec ${radicle-node}/bin/${bin} "$@"
    '';
  radicle-shared = pkgs.symlinkJoin {
    name = "radicle-shared";
    paths = [
      (wrap "rad")
      (wrap "git-remote-rad")
      radicle-node
    ];
  };
in
{
  clan.core.vars.generators.rad = {
    files."radicle.key" = {
      owner = "rad";
      group = "rad";
      mode = "0440";
    };
    files."radicle.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "radicle ${config.networking.hostName}" -f "$out/radicle.key"
      mv "$out/radicle.key.pub" "$out/radicle.pub"
    '';
  };

  users.users.rad = {
    isSystemUser = true;
    group = "rad";
    home = radHome;
  };
  users.groups.rad = { };
  users.users.mainUser.extraGroups = [ "rad" ];

  environment.systemPackages = [ radicle-shared ];
  environment.variables.RAD_HOME = radHome;

  systemd.tmpfiles.rules = [
    "d ${radHome} 2770 rad rad -"
    "d ${radHome}/cobs 2770 rad rad -"
    "d ${radHome}/keys 2770 rad rad -"
    "d ${radHome}/node 2770 rad rad -"
    "d ${radHome}/storage 2770 rad rad -"
    "L+ ${radHome}/keys/radicle - - - - ${generator.files."radicle.key".path}"
    "L+ ${radHome}/keys/radicle.pub - - - - ${generator.files."radicle.pub".path}"
    "L+ ${radHome}/config.json - - - - ${configFile}"
    # SQLite creates databases 0644 regardless of umask, which would lock the
    # second party out ("attempt to write a readonly database"). Pre-create
    # them empty and group-writable (an empty file is a valid empty database;
    # -wal/-shm copy the main file's mode). Adjusts mode on every boot too.
    "f ${radHome}/cobs/cache.db 0664 rad rad -"
    "f ${radHome}/node/node.db 0664 rad rad -"
    "f ${radHome}/node/notifications.db 0664 rad rad -"
    "f ${radHome}/node/policies.db 0664 rad rad -"
  ];

  systemd.services.rad-node = {
    description = "Radicle node (machine identity, ${radHome})";
    documentation = [ "man:radicle-node(1)" ];
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      # rad stats $HOME/.gitconfig
      HOME = radHome;
      RAD_HOME = radHome;
    };
    path = [ pkgs.gitMinimal ];
    serviceConfig = {
      User = "rad";
      Group = "rad";
      UMask = "0002";
      # --force: reclaim a control socket left behind by an unclean shutdown.
      ExecStart = "${radicle-node}/bin/radicle-node --force";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
