{ self, ... }:
{
  perSystem =
    { lib, pkgs, ... }:
    let
      # The Android wrapper's package name (android/AndroidManifest.xml).
      androidPackage = "us.lassul.assist";
      # Written by `clan vars generate coaxmetal` (machines/coaxmetal/hermes-voice.nix);
      # until then there is no assetlinks.json and Chrome opens the app as a
      # Custom Tab.
      fingerprint = self + "/vars/per-machine/coaxmetal/hermes-voice-android-signing/fingerprint/value";
      assetlinks = pkgs.writeText "assetlinks.json" (
        builtins.toJSON [
          {
            # use_as_origin: the app's postMessages to the page (android/src/…/Link.java).
            relation = [
              "delegate_permission/common.handle_all_urls"
              "delegate_permission/common.use_as_origin"
            ];
            target = {
              namespace = "android_app";
              package_name = androidPackage;
              sha256_cert_fingerprints = [ (lib.removeSuffix "\n" (builtins.readFile fingerprint)) ];
            };
          }
        ]
      );
      icon = pkgs.runCommand "hermes-voice-icon" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
        mkdir $out
        for size in 192 512; do
          magick -size 512x512 xc:'#111' -fill '#4fb477' -draw 'circle 256,256 256,128' \
            -resize ''${size}x$size -strip -define png:exclude-chunks=date,time \
            $out/icon-$size.png
        done
      '';
      static = pkgs.runCommand "hermes-voice-static" { } ''
        cp -r ${./static} $out
        chmod u+w $out
        cp ${icon}/*.png $out/
        ${lib.optionalString (builtins.pathExists fingerprint) ''
          mkdir $out/.well-known
          cp ${assetlinks} $out/.well-known/assetlinks.json
        ''}
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
      # Full-duplex voice conversations with Hermes: gpt-live-1 in the
      # browser, delegating real work to the Hermes API server.
      packages.hermes-voice =
        (pkgs.writeShellApplication {
          name = "hermes-voice";
          # A later --config on the command line overrides the packaged one.
          text = ''
            export HERMES_VOICE_STATIC=${static}
            exec ${pkgs.python3}/bin/python3 ${./hermes_voice.py} --config ${./config.json} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };

      # The voice page as Android app and digital assistant (Trusted Web
      # Activity), unsigned.
      packages.hermes-voice-android = android;
      checks.hermes-voice-android = android;

      # Aligns and signs the APK with the keystore from
      # `clan vars get coaxmetal hermes-voice-android-signing/keystore`.
      packages.hermes-voice-android-sign = pkgs.writeShellApplication {
        name = "hermes-voice-android-sign";
        runtimeInputs = [ pkgs.jdk17_headless ];
        text = ''
          PATH=${android.buildTools}:$PATH
          if [ $# -lt 3 ]; then
            echo "usage: hermes-voice-android-sign KEYSTORE PASSWORD_FILE OUT_APK [UNSIGNED_APK]" >&2
            exit 1
          fi
          aligned=$(mktemp)
          trap 'rm -f "$aligned"' EXIT
          zipalign -f -p 4 "''${4:-${android}/hermes-voice-android-unsigned.apk}" "$aligned"
          apksigner sign --ks "$1" --ks-pass "file:$2" --v4-signing-enabled false --out "$3" "$aligned"
          apksigner verify --print-certs "$3"
        '';
      };
    };
}
