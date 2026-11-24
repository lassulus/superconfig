{ ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      extensionId = "passkey-firefox@lassul.us";
      version = (lib.importJSON ./extension/manifest.json).version;
      psl = "${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat";
    in
    {
      # Native messaging host (bin/passkey-firefox-host, manifest in
      # lib/mozilla/native-messaging-hosts): lists, reads and writes
      # www/<rp>/passkey*.age with our pass, so age-detect, the plugins and the
      # PIN prompts work as on the command line.
      packages.passkey-firefox-host = pkgs.stdenv.mkDerivation {
        pname = "passkey-firefox-host";
        inherit version;
        src = ./.;
        nativeBuildInputs = [
          pkgs.makeWrapper
          pkgs.ruff
          pkgs.python3.pkgs.mypy
        ];
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          ruff check host.py
          ruff format --check host.py
          mypy --strict host.py
          runHook postCheck
        '';
        installPhase = ''
          runHook preInstall
          install -Dm644 host.py $out/libexec/host.py
          # Firefox may start it with a bare PATH (macOS Dock, tests); age-detect
          # in pass needs coreutils/grep/sed from somewhere
          makeWrapper ${pkgs.python3}/bin/python3 $out/bin/passkey-firefox-host \
            --add-flags $out/libexec/host.py \
            --prefix PATH : ${lib.makeBinPath [ self'.packages.pass ]} \
            --suffix PATH : ${
              lib.makeBinPath [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
              ]
            }
          mkdir -p $out/lib/mozilla/native-messaging-hosts
          cat > $out/lib/mozilla/native-messaging-hosts/passkey_firefox.json <<EOF
          {
            "name": "passkey_firefox",
            "description": "passkeys of the passage store",
            "path": "$out/bin/passkey-firefox-host",
            "type": "stdio",
            "allowed_extensions": ["${extensionId}"]
          }
          EOF
          runHook postInstall
        '';
      };

      # Unsigned .xpi with the public suffix list (RP ID checks), for the
      # NixOS firefox-devedition (xpinstall.signatures.required is off).
      # Release Firefox needs it signed by addons.mozilla.org.
      packages.passkey-firefox-extension =
        pkgs.runCommand "passkey-firefox-extension"
          {
            nativeBuildInputs = [
              pkgs.zip
              pkgs.nodejs
              pkgs.python3
            ];
          }
          ''
            cp -r ${./extension} extension
            chmod -R u+w extension
            cp ${psl} extension/public_suffix_list.dat
            node ${./tests/unit.mjs} extension ${./host.py}
            mkdir -p $out
            cd extension
            zip -r "$out/${extensionId}.xpi" ./*
          '';
    };
}
