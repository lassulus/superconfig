{
  fetchFromGitHub,
  lib,
  stdenvNoCC,

  # build
  qt6,
  noctalia-qs,

  # runtime deps
  bluez,
  brightnessctl,
  cliphist,
  ddcutil,
  wlsunset,
  wl-clipboard,
  wlr-randr,
  imagemagick,
  wget,
  python3,
  wayland-scanner,
}:
# noctalia-shell 4.x (QML on noctalia-qs), kept here because nixpkgs dropped
# it in favour of noctalia v5. Drop this file once the wrapper moves to
# nixpkgs' noctalia.
let
  runtimeDeps = [
    wget
    python3
    bluez
    brightnessctl
    cliphist
    ddcutil
    wlsunset
    wl-clipboard
    wlr-randr
    imagemagick
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "noctalia-shell";
  version = "4.7.7";

  src = fetchFromGitHub {
    owner = "noctalia-dev";
    repo = "noctalia";
    tag = "v${finalAttrs.version}";
    hash = "sha256-QszLpoDPD7JEv8B/w1U2u1ksBw/CYBDmwUTLhJrekF0=";
  };

  nativeBuildInputs = [
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtmultimedia
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/noctalia-shell $out/bin
    ln -s ${noctalia-qs}/bin/qs $out/bin/noctalia-shell

    cp -R \
      Assets Commons CREDITS.md Helpers Modules Services Shaders Scripts Widgets shell.qml \
      $out/share/noctalia-shell

    rm -R $out/share/noctalia-shell/Assets/Screenshots

    runHook postInstall
  '';

  preFixup = ''
    qtWrapperArgs+=(
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
      --prefix XDG_DATA_DIRS : ${wayland-scanner}/share
      --add-flags "-p $out/share/noctalia-shell"
    )
  '';

  meta = {
    changelog = "https://github.com/noctalia-dev/noctalia/releases/tag/v${finalAttrs.version}";
    description = "Sleek and minimal desktop shell thoughtfully crafted for Wayland, built with Quickshell";
    homepage = "https://github.com/noctalia-dev/noctalia";
    license = lib.licenses.mit;
    mainProgram = "noctalia-shell";
    platforms = noctalia-qs.meta.platforms;
  };
})
