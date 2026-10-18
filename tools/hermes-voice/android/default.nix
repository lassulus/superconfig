{
  stdenvNoCC,
  androidenv,
  fetchurl,
  jdk17_headless,
  unzip,
  zip,
  icon,
  # CI sets them per run; Android only installs updates with a higher versionCode.
  versionCode ? 1,
  versionName ? "1",
}:
let
  sdk = androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "36.0.0" ];
    includeEmulator = false;
    includeSystemImages = false;
    includeNDK = false;
  };
  sdkRoot = "${sdk.androidsdk}/libexec/android-sdk";
  buildTools = "${sdkRoot}/build-tools/36.0.0";
  androidJar = "${sdkRoot}/platforms/android-36/android.jar";
  browser = fetchurl {
    url = "https://dl.google.com/android/maven2/androidx/browser/browser/1.10.0/browser-1.10.0.aar";
    hash = "sha256-+0DR7l/ZEMnREiAIaKlTQVanqZmrwo+7PGgVouOsUVA=";
  };
in
# Unsigned release APK; tools/hermes-voice/flake-module.nix has the signer.
# Only androidx.browser's classes go in: the parts used here need none of its
# dependencies.
stdenvNoCC.mkDerivation {
  pname = "hermes-voice-android";
  version = versionName;
  src = ./.;
  nativeBuildInputs = [
    jdk17_headless
    unzip
    zip
  ];
  buildPhase = ''
    runHook preBuild
    unzip -q ${browser} classes.jar -d browser

    mkdir -p res/mipmap-xxxhdpi
    cp ${icon}/icon-192.png res/mipmap-xxxhdpi/ic_launcher.png
    ${buildTools}/aapt2 compile --dir res -o res.zip
    ${buildTools}/aapt2 link -o unsigned.apk -I ${androidJar} \
      --manifest AndroidManifest.xml res.zip \
      --min-sdk-version 34 --target-sdk-version 36 \
      --version-code ${toString versionCode} --version-name ${versionName}

    javac -source 8 -target 8 -Xlint:-options -encoding UTF-8 \
      -bootclasspath ${androidJar} -cp browser/classes.jar \
      -d classes $(find src -name '*.java')
    ${buildTools}/d8 --release --min-api 34 --lib ${androidJar} --output . \
      $(find classes -name '*.class') browser/classes.jar

    touch -d @315532800 classes.dex
    TZ=UTC zip -X -D unsigned.apk classes.dex
    runHook postBuild
  '';
  installPhase = ''
    install -Dm444 unsigned.apk $out/hermes-voice-android-unsigned.apk
  '';
  passthru = { inherit buildTools; };
}
