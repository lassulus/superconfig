{
  lib,
  stdenv,
  fetchFromGitHub,
  autoconf,
  automake,
  pkg-config,
  libpulseaudio,
  alsa-lib,
  nix-update-script,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "dectalk";
  version = "0-unstable-2026-10-08";

  src = fetchFromGitHub {
    owner = "dectalk";
    repo = "dectalk";
    rev = "986ea12ec8dac85881394d7bd7daf1f1d5098b9a";
    hash = "sha256-/6IaMJoTeIAXopqVdo65Tgi+Ldtw768lFK9RiBMFhY4=";
  };

  nativeBuildInputs = [
    autoconf
    automake
    pkg-config
  ];

  buildInputs = [
    libpulseaudio
    alsa-lib
  ];

  postPatch = ''
    # Replace git version detection with static version since .git is not available
    sed -i 's/m4_esyscmd_s(echo $(git describe --always)$(git status --porcelain | awk .*))/${
      builtins.substring 0 7 finalAttrs.src.rev
    }/' src/configure.ac
  '';

  configurePhase = ''
    runHook preConfigure
    cd src
    ./autogen.sh
    ./configure --prefix=$out
    cd ..
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -C src -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib $out/dic

    # Libraries
    cp dist/lib/*.so $out/lib/

    # Main binaries
    for bin in say dtmemory aclock; do
      if [ -f "dist/$bin" ]; then
        cp "dist/$bin" $out/bin/
      fi
    done

    # Tools
    if [ -d dist/tools ]; then
      cp dist/tools/* $out/bin/
    fi

    # Dictionaries
    cp dist/dic/* $out/dic/

    # DECtalk config — must be at $out/DECtalk.conf (compiled-in DECTALK_INSTALL_PREFIX)
    cp dist/DECtalk.conf $out/DECtalk.conf

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--version-regex"
      "(0-unstable-.*)"
      "--version=branch"
      "--system"
      "x86_64-linux"
    ];
  };

  meta = {
    description = "Modern builds of the DECtalk text-to-speech engine";
    homepage = "https://github.com/dectalk/dectalk";
    # license = lib.licenses.unfree;
    license = lib.licenses.free;
    platforms = lib.platforms.linux;
    mainProgram = "say";
  };
})
