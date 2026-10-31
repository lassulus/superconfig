# agentd (github:lassulus/agentd): coding agents (ACP harnesses) behind a
# REST API. Runs as its own `agentd` user; the harness logins (~/.omp, ...)
# live in /var/lib/agentd, agents work below /var/lib/agentd/workspace.
# Reachable only over retiolum (http://coaxmetal.r:8791) and locally;
# Hermes is a client with the API token from the `agentd` vars generator.
# omp needs a one-time login: `runuser -u agentd -- omp`, then /login.
{
  config,
  pkgs,
  self,
  ...
}:
let
  port = config.lass.servicePorts.agentd;
in
{
  imports = [ self.inputs.agentd.nixosModules.default ];

  lass.ports."8791" = "agentd";

  services.agentd = {
    enable = true;
    listen = "0.0.0.0:${toString port}";
    harnesses.omp.command = [
      "${pkgs.omp}/bin/omp"
      "acp"
    ];
    auth.tokensFile = config.clan.core.vars.generators.agentd.files.tokens.path;
  };

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
