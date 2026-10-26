{
  lib,
  stdenv,
  fetchFromGitHub,

  pkg-config,
  cmake,
  ninja,
  spirv-tools,
  qt6,
  breakpad,
  jemalloc,
  cli11,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxcb,
  libdrm,
  libgbm ? null,
  vulkan-headers,
  pipewire,
  pam,
  polkit,
  glib,
}:
# The quickshell fork noctalia-shell 4.x runs on, kept here because nixpkgs
# dropped it in favour of noctalia v5. Drop this package once noctalia-shell
# (wrapperModules/noctalia-shell) moves to nixpkgs' noctalia.
stdenv.mkDerivation (finalAttrs: {
  pname = "noctalia-qs";
  version = "0.0.12";

  src = fetchFromGitHub {
    owner = "noctalia-dev";
    repo = "noctalia-qs";
    tag = "v${finalAttrs.version}";
    hash = "sha256-79JP2QTdvp1jg7HGxAW+xzhzhLnlKUi8yGXq9nDCeH0=";
  };

  # 0.0.12 fails against Qt 6.12 ("Meta Types must be fully defined" in the
  # hyprland ipc mocs). qt-6.12.patch backports quickshell 5d5d49873f ("all:
  # use MOC includes instead of opaque pointer definitions") to the fork,
  # whose i3 getters are non-const.
  patches = [ ./qt-6.12.patch ];

  nativeBuildInputs = [
    cmake
    ninja
    spirv-tools
    pkg-config
    qt6.qtwayland
    qt6.wrapQtAppsHook
    wayland-scanner
  ];

  buildInputs = [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtwayland
    qt6.qtsvg
    cli11
    wayland
    wayland-protocols
    libdrm
    libgbm
    vulkan-headers
    breakpad
    jemalloc
    libxcb
    pam
    pipewire
    polkit
    glib
  ];

  cmakeFlags = [
    (lib.cmakeFeature "DISTRIBUTOR" "Nixpkgs")
    (lib.cmakeBool "DISTRIBUTOR_DEBUGINFO_AVAILABLE" true)
    (lib.cmakeFeature "INSTALL_QML_PREFIX" qt6.qtbase.qtQmlPrefix)
    (lib.cmakeFeature "GIT_REVISION" "tag-v${finalAttrs.version}")
    (lib.cmakeBool "NIX_STORE_DIR_SKIP_WATCH" true)
    (lib.cmakeFeature "NIX_STORE_DIR" builtins.storeDir)
  ];

  cmakeBuildType = "Release";

  meta = {
    homepage = "https://github.com/noctalia-dev/noctalia-qs";
    description = "Flexible QtQuick based desktop shell toolkit";
    license = lib.licenses.lgpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "quickshell";
  };
})
