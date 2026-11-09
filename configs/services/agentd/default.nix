# agentd (github:lassulus/agentd): coding agents (ACP harnesses) behind a
# REST API, the base every agentd host imports; its port and host-specific
# extras live in that machine's config.
# Runs as its own `agentd` user; the harness logins (~/.omp, ...) live in
# /var/lib/agentd. omp needs a one-time login per host:
# `runuser -u agentd -- omp`, then /login.
# Reachable only over retiolum and locally. Hermes is a client with the API
# token from the shared `agentd` vars generator below, agentd-web (web.nix)
# with the user's id.lassul.us login (oidc.nix).
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
  imports = [
    self.inputs.agentd.nixosModules.default
    ./oidc.nix
  ];

  services.agentd = {
    enable = true;
    listen = "0.0.0.0:${toString port}";
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
}
