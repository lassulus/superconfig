# Hermes' API token for agentd, one for every agentd host (coaxmetal,
# neoprism): shared, so the token in Hermes' .env (hermes-env generator in
# machines/coaxmetal/hermes.nix) is the one each agentd checks. agentd only
# gets its sha256; the raw token is only read at generation time.
{ pkgs, ... }:
{
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
