# auth_oidc tests index the person data as a tuple, Home Assistant 2026.11 made it a PersonData dataclass (fixed on nixpkgs master)
{ lib, ... }:
{
  nixpkgs.overlays = [
    (_final: prev: {
      home-assistant-custom-components = prev.home-assistant-custom-components // {
        auth_oidc =
          assert lib.assertMsg
            (!lib.hasInfix "PersonData" prev.home-assistant-custom-components.auth_oidc.postPatch)
            "nixpkgs auth_oidc has the PersonData test fix now, remove configs/build-fixes/hass-auth-oidc.nix";
          prev.home-assistant-custom-components.auth_oidc.overrideAttrs (old: {
            postPatch = old.postPatch + ''
              substituteInPlace tests/test_hass_auth_provider.py \
                --replace-fail "hass.data[PERSON_DOMAIN][1]" "hass.data[PERSON_DOMAIN].storage_collection"
            '';
          });
      };
    })
  ];
}
