{ pkgs, ... }:
{
  # Bearer token of hermes-voice's API routes. Shared: coaxmetal
  # (machines/coaxmetal/hermes-voice.nix) checks it, neoprism
  # (configs/hermes-proxy.nix) adds it to logged-in requests to
  # assist.lassul.us. Both machines import this file so the shared generator
  # definition stays identical. Read it out for clients on retiolum with
  #   clan vars get coaxmetal hermes-voice/access-token
  clan.core.vars.generators.hermes-voice = {
    share = true;
    files."access-token" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/access-token"
    '';
  };
}
