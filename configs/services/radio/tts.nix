{ pkgs, self, ... }:
let
  model = pkgs.runCommand "model" { } ''
    mkdir -p $out
    ln -s ${
      pkgs.fetchurl {
        url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/libritts/high/en_US-libritts-high.onnx?download=true";
        hash = "sha256-kSelWeEWA/ELNm0aIKx0JoJggdvFId5MJCDFdyjXPw8=";
      }
    } $out/model.onnx
    ln -s ${
      pkgs.fetchurl {
        url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/libritts/high/en_US-libritts-high.onnx.json?download=true";
        hash = "sha256-Lv3G1/lUWIuBgBMsvZuAAZM/3QCTLJK8kv0NICip6z0=";
      }
    } $out/model.onnx.json
  '';

  tts = pkgs.writers.writeBashBin "tts" ''
    set -efu
    set -x

    offset=0
    OUTPUT=$(mktemp -d)
    trap 'rm -rf "$OUTPUT"' EXIT
    SPEAKER=$[ $RANDOM % 900 ]
    while read line; do
      # skip empty lines, piper crashes on empty input
      if [ -z "$line" ]; then
        continue
      fi
      filename=$(printf '%04d' $offset).wav
      echo "$line" |
        ${self.packages.${pkgs.stdenv.hostPlatform.system}.piper-tts}/bin/piper \
          --model ${model}/model.onnx \
          -s "$SPEAKER" \
          -f "$OUTPUT"/"$filename" >/dev/null

      ((offset+=1))
    done

    ${pkgs.sox}/bin/sox "$OUTPUT"/*.wav "$OUTPUT"/all.wav
    cat "$OUTPUT"/all.wav
  '';
in
{
  environment.systemPackages = [
    tts
  ];
}
