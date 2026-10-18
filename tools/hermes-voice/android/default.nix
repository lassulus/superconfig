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
  # WebRTC for Android (LiveKit's build of Google's libwebrtc): the Java API
  # and the native library, which needs none of the AAR's other files.
  webrtc = fetchurl {
    url = "https://repo1.maven.org/maven2/io/github/webrtc-sdk/android/150.7871.01/android-150.7871.01.aar";
    hash = "sha256-ChYnsaSMK8F9mkDWL8R71FFm9EoxHpWRfxR8QC3jebA=";
  };
in
# Unsigned release APK; tools/hermes-voice/flake-module.nix has the signer.
# arm64 only: the app runs on Pixels.
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
    unzip -q ${webrtc} classes.jar 'jni/arm64-v8a/*' -d webrtc

    mkdir -p res/mipmap-xxxhdpi
    cp ${icon}/icon-192.png res/mipmap-xxxhdpi/ic_launcher.png
    ${buildTools}/aapt2 compile --dir res -o res.zip
    ${buildTools}/aapt2 link -o unsigned.apk -I ${androidJar} \
      --manifest AndroidManifest.xml res.zip \
      --min-sdk-version 34 --target-sdk-version 36 \
      --version-code ${toString versionCode} --version-name ${versionName}

    javac -source 8 -target 8 -Xlint:-options -encoding UTF-8 \
      -bootclasspath ${androidJar} -cp webrtc/classes.jar \
      -d classes $(find src -name '*.java')
    ${buildTools}/d8 --release --min-api 34 --lib ${androidJar} --output . \
      $(find classes -name '*.class') webrtc/classes.jar

    mkdir -p lib/arm64-v8a
    cp webrtc/jni/arm64-v8a/*.so lib/arm64-v8a/
    touch -d @315532800 classes*.dex lib/arm64-v8a/*.so
    TZ=UTC zip -X -D unsigned.apk classes*.dex
    TZ=UTC zip -X -D -0 unsigned.apk lib/arm64-v8a/*.so
    runHook postBuild
  '';
  installPhase = ''
    install -Dm444 unsigned.apk $out/hermes-voice-android-unsigned.apk
  '';
  passthru = { inherit buildTools; };
}
