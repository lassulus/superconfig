{
  perSystem =
    { pkgs, ... }:
    let
      icon = pkgs.runCommand "slopulus-voice-icon" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
        mkdir $out
        for size in 192 512; do
          magick -size 512x512 xc:'#111' -fill '#4fb477' -draw 'circle 256,256 256,128' \
            -resize ''${size}x$size -strip -define png:exclude-chunks=date,time \
            $out/icon-$size.png
        done
      '';
      static = pkgs.runCommand "slopulus-voice-static" { } ''
        cp -r ${./static} $out
        chmod u+w $out
        cp ${icon}/*.png $out/
      '';
      # The SDK is unfree; it only builds the APK and is not part of any system.
      inherit
        (import pkgs.path {
          inherit (pkgs.stdenv.hostPlatform) system;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        })
        androidenv
        ;
      android = pkgs.callPackage ./android { inherit icon androidenv; };
    in
    {
      # Full-duplex voice conversations with slopulus: gpt-live-1.1 in the
      # browser, delegating real work to the Hermes API server.
      packages.slopulus-voice =
        (pkgs.writeShellApplication {
          name = "slopulus-voice";
          # A later --config on the command line overrides the packaged one.
          text = ''
            export SLOPULUS_VOICE_STATIC=${static}
            exec ${pkgs.python3}/bin/python3 ${./slopulus_voice.py} --config ${./config.json} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };

      # Tasks of a call against a fake Hermes API server: parallel runs,
      # stopping one task, the task list, Matrix threads, hang-up.
      checks.slopulus-voice =
        pkgs.runCommand "slopulus-voice-test" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            cp ${./slopulus_voice.py} slopulus_voice.py
            cp ${./test_slopulus_voice.py} test_slopulus_voice.py
            python3 -m unittest test_slopulus_voice 2>&1
            touch $out
          '';

      # The Android app: holds calls itself (WebRTC) and answers the headset's
      # voice button, unsigned.
      packages.slopulus-voice-android = android;

      # Aligns and signs the APK with the keystore from
      # `clan vars get coaxmetal hermes-voice-android-signing/keystore`.
      packages.slopulus-voice-android-sign = pkgs.writeShellApplication {
        name = "slopulus-voice-android-sign";
        runtimeInputs = [ pkgs.jdk17_headless ];
        text = ''
          PATH=${android.buildTools}:$PATH
          if [ $# -lt 3 ]; then
            echo "usage: slopulus-voice-android-sign KEYSTORE PASSWORD_FILE OUT_APK [UNSIGNED_APK]" >&2
            exit 1
          fi
          aligned=$(mktemp)
          trap 'rm -f "$aligned"' EXIT
          zipalign -f -p 4 "''${4:-${android}/slopulus-voice-android-unsigned.apk}" "$aligned"
          apksigner sign --ks "$1" --ks-pass "file:$2" --v4-signing-enabled false --out "$3" "$aligned"
          apksigner verify --print-certs "$3"
        '';
      };
    };
}
