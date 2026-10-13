{
  python3,
  fetchurl,
  fetchFromGitHub,
}:
let
  # Create a python environment with our overrides
  python = python3.override {
    self = python;
    packageOverrides = final: prev: {
      # Override kokoro with a more recent version and stdout support
      kokoro = prev.kokoro.overridePythonAttrs (old: {
        version = "0-unstable-2025-08-06";
        src = fetchFromGitHub {
          owner = "hexgrad";
          repo = "kokoro";
          rev = "dfb907a02bba8152ca444717ca5d78747ccb4bec";
          hash = "sha256-GJlc3+RCeYaAvojFFjK22nitDTWFWp6dAPJakw+//j8=";
        };
        patches = (old.patches or [ ]) ++ [
          ./stdout-support.patch
        ];
        passthru = (old.passthru or { }) // {
          # Bumps kokoro (main branch) and the spacy model wheel together.
          updateScript = ./update.sh;
        };
      });
      # Spacy model - downloaded and packaged as a python package
      spacy-en-core-web-sm = final.buildPythonPackage rec {
        pname = "en_core_web_sm";
        version = "3.8.0";
        format = "wheel";

        src = fetchurl {
          url = "https://github.com/explosion/spacy-models/releases/download/${pname}-${version}/${pname}-${version}-py3-none-any.whl";
          hash = "sha256-GTJCnbcn1L/z3u1rNM/AXfF3lPSlLusmz4ko98Gg+4U=";
        };

        propagatedBuildInputs = [ final.spacy ];

        pythonImportsCheck = [ "en_core_web_sm" ];
      };

      # Create a patched misaki that doesn't try to download spacy models
      misaki = prev.misaki.overridePythonAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # Patch out the spacy model download - we provide it as a dependency instead
          substituteInPlace misaki/en.py \
            --replace-fail "if not spacy.util.is_package(name):" "if False:" \
            --replace-fail "spacy.cli.download(name)" "pass"
        '';

        propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ final.spacy-en-core-web-sm ];
      });
    };
  };
in
python.pkgs.kokoro
