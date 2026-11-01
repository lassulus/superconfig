{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  dotnetCorePackages,
  curl,
  icu,
  openssl,
  sqlite,
  zlib,
  nix-update-script,
}:

stdenvNoCC.mkDerivation rec {
  pname = "gamarr";
  version = "1.1.0.534";

  # framework-dependent release build; runs on the nixpkgs aspnetcore runtime
  src = fetchurl {
    url = "https://github.com/gamarr-app/Gamarr/releases/download/v${version}/Gamarr.${version}.linux-x64.tar.gz";
    hash = "sha256-fn5W7n+nZrc/64wYjX8r0OoUJ3SWoLF+PjL7OIhkENA=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/gamarr
    cp -r * $out/lib/gamarr
    makeWrapper ${dotnetCorePackages.aspnetcore_10_0}/bin/dotnet $out/bin/Gamarr \
      --add-flags $out/lib/gamarr/Gamarr.dll \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [
          curl
          icu
          openssl
          sqlite
          zlib
        ]
      }
    runHook postInstall
  '';

  passthru.updateScript = nix-update-script { extraArgs = [ "--flake" ]; };

  meta = {
    description = "Radarr for games: *arr-style PVR for a game library";
    homepage = "https://github.com/gamarr-app/Gamarr";
    license = lib.licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    mainProgram = "Gamarr";
  };
}
