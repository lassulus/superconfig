{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  makeDesktopItem,
  copyDesktopItems,
  electron_43,
  nix-update-script,
}:

let
  electron = electron_43;
in
buildNpmPackage (finalAttrs: {
  pname = "moebius";
  # Upstream's last tagged release (1.0.29) only ships x86_64 binaries; build the
  # newer master commit from source so it runs natively on every platform.
  version = "1.0.29-unstable-2023-12-18";

  src = fetchFromGitHub {
    owner = "blocktronics";
    repo = "moebius";
    rev = "1f624d62654d614177635ab18a288253c3b917eb";
    hash = "sha256-Uu6vEhbXXiVbUTgC/WeF+SVCf0oLzg4OnGFZIx7SJ6I=";
  };

  npmDepsHash = "sha256-hLZF0FvyAgJVURmU6M4UYFauZz5SLvH2+6W2qDogoXU=";

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--version=branch"
    ];
  };

  # discord-rpc pulls the optional native `register-scheme` git dependency, which
  # is only used outside Electron (inside Electron it falls back to
  # app.setAsDefaultProtocolClient), so drop it and build a pure-JS closure.
  forceGitDeps = true;
  npmFlags = [
    "--omit=dev"
    "--omit=optional"
  ];

  # We ship the app on nixpkgs' Electron; don't download a private one or run the
  # electron-builder packaging step.
  env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
  dontNpmBuild = true;

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ copyDesktopItems ];

  desktopItems = lib.optionals stdenv.hostPlatform.isLinux [
    (makeDesktopItem {
      name = "moebius";
      desktopName = "Moebius";
      comment = finalAttrs.meta.description;
      exec = "moebius %U";
      icon = "moebius";
      startupWMClass = "Moebius";
      categories = [ "Graphics" ];
      mimeTypes = [ "text/x-ansi" ];
    })
  ];

  installPhase = ''
    runHook preInstall

    app=$out/libexec/moebius
    res=$app/resources
    mkdir -p "$app" "$out/bin"
    cp -r app node_modules package.json "$app/"

    # Sample art and control-character sheets the app loads at runtime.
    mkdir -p "$res"
    cp -r build/ans "$res/ans"
    cp -r build/png "$res/png"

    # The app switches resource paths on app.isPackaged; we run an unpacked tree,
    # so pin both branches to the store copy above.
    find "$app/app" -name '*.js' | while read -r f; do
      substituteInPlace "$f" \
        --replace-quiet 'remote.app.isPackaged' 'true' \
        --replace-quiet 'process.resourcesPath' "\"$res\""
    done

    # @electron/remote 2.1.0 calls the internal features.isViewApiEnabled(),
    # removed in modern Electron; guard it (the fix shipped upstream in 2.1.2).
    substituteInPlace "$app/node_modules/@electron/remote/dist/src/common/module-names.js" \
      --replace-fail 'if (!features || features.isViewApiEnabled()) {' \
                     'if (!features || !features.isViewApiEnabled || features.isViewApiEnabled()) {'

    makeWrapper ${lib.getExe electron} $out/bin/moebius \
      --add-flags "$app" \
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"
      ''}
  ''
  + lib.optionalString stdenv.hostPlatform.isLinux ''
    for size in 16 32 128 512 1024; do
      install -Dm644 build/icons/icon_''${size}x''${size}.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/moebius.png
    done
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    appdir="$out/Applications/Moebius.app/Contents"
    mkdir -p "$appdir/MacOS" "$appdir/Resources"
    cp build/icon.icns "$appdir/Resources/moebius.icns"
    makeWrapper $out/bin/moebius "$appdir/MacOS/Moebius"
    cat > "$appdir/Info.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleName</key><string>Moebius</string>
      <key>CFBundleDisplayName</key><string>Moebius</string>
      <key>CFBundleExecutable</key><string>Moebius</string>
      <key>CFBundleIdentifier</key><string>org.andyherbert.moebius</string>
      <key>CFBundleIconFile</key><string>moebius.icns</string>
      <key>CFBundleShortVersionString</key><string>${finalAttrs.version}</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>LSMinimumSystemVersion</key><string>10.13</string>
      <key>NSHighResolutionCapable</key><true/>
    </dict>
    </plist>
    EOF
  ''
  + ''
    runHook postInstall
  '';

  meta = {
    description = "Modern ANSI and ASCII art editor with a Photoshop-style half-block brush";
    homepage = "https://blocktronics.github.io/moebius/";
    downloadPage = "https://github.com/blocktronics/moebius/releases";
    license = lib.licenses.asl20;
    maintainers = [ ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    mainProgram = "moebius";
  };
})
