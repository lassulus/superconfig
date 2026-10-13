{
  lib,
  stdenvNoCC,
  fetchzip,
  unzip,
  nix-update-script,
}:

stdenvNoCC.mkDerivation rec {
  pname = "secretive";
  version = "4.0.0";

  src = fetchzip {
    url = "https://github.com/maxgoedjen/secretive/releases/download/v${version}/Secretive.zip";
    hash = "sha256-AP/ubwV9h/9EYj7J6psSUAkzBjee3QB3a4/7hv7nWYk=";
    stripRoot = false;
  };

  nativeBuildInputs = [ unzip ];

  dontBuild = true;
  dontConfigure = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications
    cp -R Secretive.app $out/Applications/

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script { extraArgs = [ "--flake" ]; };

  meta = {
    description = "Store SSH keys in the Secure Enclave";
    homepage = "https://github.com/maxgoedjen/secretive";
    changelog = "https://github.com/maxgoedjen/secretive/releases/tag/v${version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ ];
    platforms = lib.platforms.darwin;
    mainProgram = "Secretive";
  };
}
