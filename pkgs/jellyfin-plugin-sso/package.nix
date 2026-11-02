{
  lib,
  stdenvNoCC,
  fetchzip,
  nix-update-script,
}:

stdenvNoCC.mkDerivation rec {
  pname = "jellyfin-plugin-sso";
  version = "6.1.0.0";

  # Release zip as the Jellyfin plugin catalog installs it (DLLs + meta.json).
  # MaxRink's fork: 9p4/jellyfin-plugin-sso is archived and stops at Jellyfin 10.11.
  src = fetchzip {
    url = "https://github.com/MaxRink/jellyfin-plugin-sso/releases/download/v${version}/sso-auth_${version}.zip";
    hash = "sha256-ZuQeEeCjzwLT5lqjhNbMCgcHeDV7UIrPmEP2W0BwLlw=";
    stripRoot = false;
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    cp -r . $out
    runHook postInstall
  '';

  passthru = {
    # directory name the Jellyfin plugin manager uses, <name>_<version>
    pluginDir = "SSO-Auth_${version}";
    updateScript = nix-update-script { extraArgs = [ "--flake" ]; };
  };

  meta = {
    description = "Jellyfin plugin for logins via OpenID Connect or SAML";
    homepage = "https://github.com/MaxRink/jellyfin-plugin-sso";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
