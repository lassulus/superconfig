# agentd (github:lassulus/agentd): coding agents (ACP harnesses) behind a
# REST API. Runs as its own `agentd` user; the harness logins (~/.omp, ...)
# live in /var/lib/agentd. Clones are in ~/src, and every agent works in its
# own git worktree in ~/worktrees (omp/skills/git-worktrees, omp/RULES.md).
# Reachable only over retiolum (http://coaxmetal.r:8791) and locally;
# Hermes is a client with the API token from the `agentd` vars generator.
# omp needs a one-time login: `runuser -u agentd -- omp`, then /login.
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
  pinned = self.inputs.agentd.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [ self.inputs.agentd.nixosModules.default ];

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
    harnesses.omp.command = [
      "${pkgs.omp}/bin/omp"
      "acp"
    ];
    # nix, so agents can build and test (and deploy a dev agentd)
    path = options.services.agentd.path.default ++ [ config.nix.package ];
    auth.tokensFile = config.clan.core.vars.generators.agentd.files.tokens.path;
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
  ];

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ port ];

  # API token for Hermes: the raw token goes into Hermes' .env
  # (machines/coaxmetal/hermes.nix), agentd only gets its sha256.
  clan.core.vars.generators.agentd = {
    files.hermes-token = { };
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

  lass.backup.state.agentd = {
    folders = [ "/var/lib/agentd" ];
    exclude = [ "/var/lib/agentd/.cache" ];
  };
}
