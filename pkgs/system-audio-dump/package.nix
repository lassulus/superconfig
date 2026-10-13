{
  lib,
  fetchFromGitHub,
  swift,
  swiftpm,
  swiftPackages,
  nix-update-script,
}:

swiftPackages.stdenv.mkDerivation {
  pname = "system-audio-dump";
  version = "1-unstable-2025-09-01";

  src = fetchFromGitHub {
    owner = "sohzm";
    repo = "systemAudioDump";
    rev = "19caa4f6c0661c03a10d1f08c79a11f0b00f251a";
    hash = "sha256-H2TeB7/Meq7EvfW7zLZn5GGFrKwCyZuJvafv61ZWdrA=";
  };

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  postPatch = ''
    # Downgrade swift-tools-version from 6.0 to 5.10 and macOS from v15 to v14
    sed -i 's/swift-tools-version:6.0/swift-tools-version:5.10/' Package.swift
    sed -i 's/.macOS(.v15)/.macOS(.v14)/' Package.swift

    # Patch Swift 6 / macOS 15 features in source
    # Remove @retroactive attribute (Swift 6 feature for silencing conformance warnings)
    sed -i 's/@retroactive //' Sources/SystemAudioDump/main.swift
    # Remove captureMicrophone (macOS 15+ only, defaults to false anyway)
    sed -i '/captureMicrophone/d' Sources/SystemAudioDump/main.swift
  '';

  buildPhase = ''
    runHook preBuild
    swift build -c release
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp .build/release/SystemAudioDump $out/bin/system-audio-dump
    runHook postInstall
  '';

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--version=branch"
    ];
  };

  meta = {
    description = "macOS CLI that captures system audio and outputs raw PCM to stdout";
    homepage = "https://github.com/sohzm/systemAudioDump";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "system-audio-dump";
  };
}
