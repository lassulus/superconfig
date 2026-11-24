# Tokens of the gateway's JSON API: Hermes' raw token (only read into its .env)
# and the `<name> <sha256>` tokens file for the gateway. Shared generator, so
# every importer (proxy.nix, coaxmetal's slopulus.nix) must define it equally.
{ pkgs, ... }:
{
  clan.core.vars.generators.browser-sessions-api = {
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
