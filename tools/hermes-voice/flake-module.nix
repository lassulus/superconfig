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
            relation = [ "delegate_permission/common.handle_all_urls" ];
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
    };
}
