# coaxmetal's agentd (base in default.nix), http://coaxmetal.r:8791.
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
  home = "/var/lib/agentd";
  # pushes to the slopulus account's forks on knot.lassul.us; the public
  # key is published on that account (tangled.org settings -> keys)
  sshConfig = pkgs.writeText "agentd-ssh-config" ''
    Host knot.lassul.us
      IdentityFile ${config.clan.core.vars.generators.agentd-ssh.files.id_ed25519.path}
      IdentitiesOnly yes
  '';
  pinned = self.inputs.agentd.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ ./default.nix ];

  lass.ports."8791" = "agentd";

  services.agentd = {
    package = pkgs.writeShellScriptBin "agentd" ''
      if [ -x ${home}/dev/agentd/bin/agentd ]; then
        exec ${home}/dev/agentd/bin/agentd "$@"
      fi
      exec ${pinned}/bin/agentd "$@"
    '';
    # agents may start in ~/src or in a worktree under ~/worktrees
    workspaceRoot = home;
    # nix, so agents can build and test (and deploy a dev agentd)
    path = options.services.agentd.path.default ++ [ config.nix.package ];
    # Pending permissions and questions go to Matrix via Hermes' webhook
    # (route below), signed with the key Hermes checks webhooks against.
    notify = [
      {
        url = "http://127.0.0.1:${toString config.lass.servicePorts.hermes-webhook}/webhooks/agentd";
        secretFile = config.clan.core.vars.generators.hermes-api.files."api_key".path;
      }
    ];
  };

  # deliver_only: posted to the Matrix home room as is, no agent turn.
  services.hermes-agent.settings.platforms.webhook.extra.routes.agentd = {
    deliver = "matrix";
    deliver_only = true;
    prompt = "agentd {agent.name} ({agent.id}) in {agent.cwd} waits:\n\n{text}";
  };

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

  clan.core.vars.generators.agentd-ssh = {
    files.id_ed25519 = {
      owner = "agentd";
      mode = "0400";
    };
    files."id_ed25519.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -C "agentd@coaxmetal" -f "$out/id_ed25519"
    '';
  };

  # knot2's own host key (knot.nix, ssh_host_key on neoprism)
  programs.ssh.knownHosts."knot.lassul.us".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ368b3nf45MzdgNQC4EkRpQTsssdhj3IEOoo4GdaX2";

  lass.backup.state.agentd = {
    folders = [ "/var/lib/agentd" ];
    exclude = [ "/var/lib/agentd/.cache" ];
  };
}
