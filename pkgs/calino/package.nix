{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  nix-update-script,
}:

# Calino: a static, local-first CalDAV web client. Accounts, settings and the
# event cache live in the browser; there is no backend. The CalDAV server has
# to allow the origin Calino is served from via CORS.
stdenv.mkDerivation (finalAttrs: {
  pname = "calino";
  version = "0.43.0";

  src = fetchFromGitHub {
    owner = "Ivan-Malinovski";
    repo = "calino";
    tag = "v${finalAttrs.version}";
    hash = "sha256-eSU57MOdgWCU1j94nX50owqi8W5egErWl8XsZxOGxas=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 4;
    hash = "sha256-SXxtSCIXIWLTQDB/qfJKM2f4EJmjoraX08ImzEXYFqk=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmConfigHook
  ];

  buildPhase = ''
    runHook preBuild
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';

  passthru.updateScript = nix-update-script { extraArgs = [ "--flake" ]; };

  meta = {
    description = "Local-first CalDAV calendar web client (static files)";
    homepage = "https://github.com/Ivan-Malinovski/calino";
    changelog = "https://github.com/Ivan-Malinovski/calino/blob/v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
})
