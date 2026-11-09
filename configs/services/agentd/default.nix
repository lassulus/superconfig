# agentd (github:lassulus/agentd): coding agents (ACP harnesses) behind a
# REST API, the same on every agentd host: http://<host>.r:8791.
# Runs as its own `agentd` user; the harness logins (~/.omp, ...) live in
# /var/lib/agentd. omp needs a one-time login per host:
# `runuser -u agentd -- omp`, then /login.
# Reachable only over retiolum and locally. Hermes is a client with the API
# token from the shared `agentd` vars generator below, agentd-web (web.nix)
# with the user's id.lassul.us login (oidc.nix).
#
# Clones are in ~/src, and every agent works in its own git worktree in
# ~/worktrees (omp/skills/git-worktrees, omp/RULES.md).
#
# Dev mode: agentd runs ~/dev/agentd/bin/agentd when that link exists, else
# the pinned package. `nix build --out-link ~/dev/agentd <agentd worktree>`
# as the agentd user restarts it onto that build; `rm ~/dev/agentd` goes
# back to the pinned one (omp/skills/agentd-dev).
{
  config,
  options,
  pkgs,
  self,
  ...
}:
let
  port = config.lass.servicePorts.agentd;
  home = "/var/lib/agentd";
  # pushes to the slopulus account's forks on knot.lassul.us; each host's
  # public key is published on that account (tangled.org settings -> keys)
  sshConfig = pkgs.writeText "agentd-ssh-config" ''
    Host knot.lassul.us
      IdentityFile ${config.clan.core.vars.generators.agentd-ssh.files.id_ed25519.path}
      IdentitiesOnly yes
  '';
  pinned = self.inputs.agentd.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [
    self.inputs.agentd.nixosModules.default
    ./oidc.nix
  ];

  lass.ports."8791" = "agentd";

  services.agentd = {
    enable = true;
    package = pkgs.writeShellScriptBin "agentd" ''
      if [ -x ${home}/dev/agentd/bin/agentd ]; then
        exec ${home}/dev/agentd/bin/agentd "$@"
      fi
      exec ${pinned}/bin/agentd "$@"
    '';
    listen = "0.0.0.0:${toString port}";
    # agents may start in ~/src or in a worktree under ~/worktrees
    workspaceRoot = home;
    # nix, so agents can build and test (and deploy a dev agentd)
    path = options.services.agentd.path.default ++ [ config.nix.package ];
    harnesses.omp.command = [
      "${pkgs.omp}/bin/omp"
      "acp"
      # like interactive omp: in ACP mode omp asks for every bash call
      # unless yolo is set explicitly
      "--yolo"
    ];
    auth.tokensFile = config.clan.core.vars.generators.agentd.files.tokens.path;
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];

  # Restart onto a new dev build. Watching the directory, not the link:
  # `nix build --out-link` renames a new link over the old one, which a
  # watch on the link itself does not see.
  systemd.paths.agentd-dev = {
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathChanged = "${home}/dev";
      Unit = "agentd-dev-restart.service";
    };
  };
  systemd.services.agentd-dev-restart = {
    serviceConfig.Type = "oneshot";
    script = "${config.systemd.package}/bin/systemctl restart agentd.service";
  };

  # Inherited by every agent.
  systemd.services.agentd.environment = {
    GIT_AUTHOR_NAME = "slopulus";
    GIT_AUTHOR_EMAIL = "slop@lassul.us";
    GIT_COMMITTER_NAME = "slopulus";
    GIT_COMMITTER_EMAIL = "slop@lassul.us";
  };

  # omp's user config: our skills and rules, read-only from the store. The
  # rest of ~/.omp/agent (login, sessions) stays omp's.
  systemd.tmpfiles.rules = [
    "d ${home}/src 0700 agentd agentd -"
    "d ${home}/worktrees 0700 agentd agentd -"
    "d ${home}/dev 0700 agentd agentd -"
    "d ${home}/.omp 0700 agentd agentd -"
    "d ${home}/.omp/agent 0700 agentd agentd -"
    "L+ ${home}/.omp/agent/skills - - - - ${./omp/skills}"
    "L+ ${home}/.omp/agent/RULES.md - - - - ${./omp/RULES.md}"
    "d ${home}/.ssh 0700 agentd agentd -"
    "L+ ${home}/.ssh/config - - - - ${sshConfig}"
  ];

  # Hermes' API token, one for every agentd host: shared, so the token in
  # Hermes' .env (hermes-env generator in machines/coaxmetal/hermes.nix) is
  # the one each agentd checks. agentd only gets its sha256; the raw token is
  # only read at generation time.
  clan.core.vars.generators.agentd = {
    share = true;
    files.hermes-token.deploy = false;
    files.tokens = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/hermes-token"
      printf 'hermes %s\n' "$(sha256sum < "$out/hermes-token" | cut -d' ' -f1)" > "$out/tokens"
    '';
  };

  # Per host: every host has its own key on the slopulus account.
  clan.core.vars.generators.agentd-ssh = {
    files.id_ed25519 = {
      owner = "agentd";
      mode = "0400";
    };
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "agentd@${config.networking.hostName}" -f "$out/id_ed25519"
    '';
  };

  # knot2's own host key (configs/services/git/knot.nix)
  programs.ssh.knownHosts."knot.lassul.us".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ368b3nf45MzdgNQC4EkRpQTsssdhj3IEOoo4GdaX2";

  lass.backup.state.agentd = {
    folders = [ "/var/lib/agentd" ];
    exclude = [ "/var/lib/agentd/.cache" ];
  };
}
