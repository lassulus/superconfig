{ pkgs, ... }:
{
  # Bearer token of atlas-cast-control, the livestream switch on atlas
  # (machines/atlas/cast.nix). Shared: atlas checks it, Home Assistant on
  # acheron (configs/hass/atlas-cast.nix) sends it; hass.env puts it into
  # the container's environment. Both machines import this file so the
  # shared generator definition stays identical.
  clan.core.vars.generators.atlas-cast-control = {
    share = true;
    files.token = { };
    files."hass.env" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/token"
      printf 'ATLAS_CAST_AUTHORIZATION=Bearer %s\n' "$(cat "$out/token")" > "$out/hass.env"
    '';
  };
}
