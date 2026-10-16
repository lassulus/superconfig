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
      python = pkgs.python3.withPackages (ps: [ ps.mcp ]);
      extensionId = "browser-mcp@lassul.us";
      pinentry =
        if pkgs.stdenv.hostPlatform.isDarwin then
          "${pkgs.pinentry_mac}/${pkgs.pinentry_mac.binaryPath}"
        else
          "${self'.packages.pinentry-rofi}/bin/pinentry-rofi";
    in
    {
      # stdio MCP server (bin/browser-mcp) plus the native messaging host
      # Firefox spawns for the extension (bin/browser-mcp-host, manifest in
      # lib/mozilla/native-messaging-hosts).
      packages.browser-mcp = pkgs.stdenv.mkDerivation {
        pname = "browser-mcp";
        version = (lib.importJSON ./extension/manifest.json).version;
        src = ./.;
        nativeBuildInputs = [
          pkgs.makeWrapper
          pkgs.ruff
          python.pkgs.mypy
        ];
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          ruff check browser_mcp.py
          ruff format --check browser_mcp.py
          ${python}/bin/python -m mypy --strict browser_mcp.py
          runHook postCheck
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 browser_mcp.py $out/libexec/browser_mcp.py
          makeWrapper ${python}/bin/python $out/bin/browser-mcp \
            --add-flags $out/libexec/browser_mcp.py
          makeWrapper ${python}/bin/python $out/bin/browser-mcp-host \
            --add-flags "$out/libexec/browser_mcp.py host"

          mkdir -p $out/lib/mozilla/native-messaging-hosts
          cat > $out/lib/mozilla/native-messaging-hosts/browser_mcp.json <<EOF
          {
            "name": "browser_mcp",
            "description": "Relay between the Browser MCP extension and browser-mcp",
            "path": "$out/bin/browser-mcp-host",
            "type": "stdio",
            "allowed_extensions": ["${extensionId}"]
          }
          EOF
          runHook postInstall
        '';
        meta.mainProgram = "browser-mcp";
      };

      # Signs the extension as unlisted on addons.mozilla.org so release
      # Firefox installs it. Bump the version in extension/manifest.json
      # first: AMO signs every version only once. Credentials come from the
      # jwt_issuer/jwt_secret fields of the rbw entry accounts.firefox.com.
      packages.browser-mcp-sign = pkgs.writeShellApplication {
        name = "browser-mcp-sign";
        runtimeInputs = [
          pkgs.web-ext
          pkgs.rbw
        ];
        text = ''
          out=''${1:-.}
          if [ -z "''${WEB_EXT_API_KEY:-}" ] || [ -z "''${WEB_EXT_API_SECRET:-}" ]; then
            if ! rbw unlocked 2>/dev/null; then
              rbw config set pinentry ${pinentry}
              rbw unlock
            fi
            WEB_EXT_API_KEY=$(rbw get --field jwt_issuer accounts.firefox.com)
            WEB_EXT_API_SECRET=$(rbw get --field jwt_secret accounts.firefox.com)
            export WEB_EXT_API_KEY WEB_EXT_API_SECRET
          fi
          # web-ext writes .amo-upload-uuid into the source dir, so sign a
          # writable copy of the extension.
          src=$(mktemp -d)
          trap 'rm -rf "$src"' EXIT
          cp -r ${./extension}/. "$src"
          chmod -R u+w "$src"
          web-ext sign \
            --channel unlisted \
            --source-dir "$src" \
            --artifacts-dir "$out"
        '';
      };
    };
}
