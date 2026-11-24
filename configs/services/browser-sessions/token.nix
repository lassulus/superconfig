# The token the gateway (proxy.nix) sends to the backends (host.nix).
# Shared, so the definition must be the same on every machine: both import
# this file.
{ pkgs, ... }:
{
  clan.core.vars.generators.browser-sessions-backend = {
    share = true;
    files.token = { };
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl rand -hex 32 > "$out"/token
    '';
  };
}
