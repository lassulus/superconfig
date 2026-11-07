{ pkgs, ... }:
{
  # Hermes's API token for neoprism's agentd (configs/services/agentd/web.nix).
  # Shared: neoprism consumes the hash, coaxmetal (machines/coaxmetal/hermes.nix)
  # the plaintext, but only at generation time via the hermes-env generator.
  # Both machines import this file so the shared definition stays identical.
  clan.core.vars.generators.agentd-neoprism-hermes = {
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
