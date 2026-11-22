{
  lib,
  stdenv,
  buildGoModule,
  buildNpmPackage,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  wrapGAppsHook3,
  util-macros,
  xorg-server,
  xorgproto,
  libx11,
  libxrandr,
  libxtst,
  libxfixes,
  libxi,
  libxcvt,
  gtk3,
  gst_all_1,
  xclip,
  xdotool,
  setxkbmap,
  nix-update-script,
}:
let
  version = "3.2.0";

  src = fetchFromGitHub {
    owner = "m1k1o";
    repo = "neko";
    tag = "v${version}";
    hash = "sha256-CgsPfqtGmP+Rys0lNgB1kRtEm+BbGS2u+xZbdBJjV+4=";
  };

  meta = {
    homepage = "https://github.com/m1k1o/neko";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };

  # The web client (vite build of client/), served by `neko` from
  # $out/share/neko/www.
  client = buildNpmPackage {
    pname = "neko-client";
    inherit version src;
    sourceRoot = "${src.name}/client";
    npmDepsHash = "sha256-S0W0vJhKZlz1gn0LQgu2jHBSwFA46qJJ+gvhS9WWfpg=";

    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';

    meta = meta // {
      description = "Web client of neko";
    };
  };

  # Xorg drivers of utils/xorg-deps: neko's input driver, which `neko`
  # feeds through the socket of its "SocketName" option, and the dummy video
  # driver v0.3.8 patched for RandR, so neko can switch screen sizes.
  xf86-input-neko = stdenv.mkDerivation {
    pname = "xf86-input-neko";
    inherit version src;
    sourceRoot = "${src.name}/utils/xorg-deps/xf86-input-neko";

    nativeBuildInputs = [
      autoreconfHook
      pkg-config
      util-macros
    ];
    buildInputs = [
      xorg-server
      xorgproto
    ];
    configureFlags = [
      "--with-xorg-module-dir=${placeholder "out"}/lib/xorg/modules"
      "--with-xorg-conf-dir=${placeholder "out"}/share/X11/xorg.conf.d"
    ];

    meta = meta // {
      description = "Xorg input driver of neko";
    };
  };

  xf86-video-dummy = stdenv.mkDerivation {
    pname = "xf86-video-dummy-neko";
    version = "0.3.8";
    inherit src;
    sourceRoot = "${src.name}/utils/xorg-deps/xf86-video-dummy/v0.3.8";
    patches = [ "${src}/utils/xorg-deps/xf86-video-dummy/01_v0.3.8_xdummy-randr.patch" ];

    nativeBuildInputs = [
      autoreconfHook
      pkg-config
      util-macros
    ];
    buildInputs = [
      xorg-server
      xorgproto
    ];
    configureFlags = [ "--with-xorg-module-dir=${placeholder "out"}/lib/xorg/modules" ];
    # its `Bool (*CreateWindow)()` is a prototype under C23
    env.NIX_CFLAGS_COMPILE = "-std=gnu17";

    meta = meta // {
      description = "Xorg dummy video driver with RandR support, as neko builds it";
    };
  };
in
buildGoModule {
  pname = "neko";
  inherit version src;
  modRoot = "server";
  vendorHash = "sha256-LjCVw5dgfesyTUnPS77RO0m2Qk4ahJasmNOHmFQkVKE=";
  subPackages = [ "cmd/neko" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/m1k1o/neko/server.gitTag=v${version}"
  ];

  nativeBuildInputs = [
    pkg-config
    wrapGAppsHook3
  ];
  buildInputs = [
    libx11
    libxrandr
    libxtst
    libxfixes
    libxi
    libxcvt
    gtk3
  ]
  ++ (with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
  ]);

  postInstall = ''
    mkdir -p $out/share/neko
    ln -s ${client} $out/share/neko/www
  '';

  # wrapGAppsHook3 puts the GStreamer plugins above on GST_PLUGIN_SYSTEM_PATH_1_0;
  # the clipboard, file chooser and keyboard layout run these tools
  preFixup = ''
    gappsWrapperArgs+=(
      --set-default NEKO_SERVER_STATIC $out/share/neko/www
      --prefix PATH : ${
        lib.makeBinPath [
          xclip
          xdotool
          setxkbmap
        ]
      }
    )
  '';

  passthru = {
    inherit client xf86-input-neko xf86-video-dummy;
    updateScript = nix-update-script {
      extraArgs = [
        "--flake"
        "--subpackage"
        "client"
      ];
    };
  };

  meta = meta // {
    description = "Self-hosted virtual browser streamed over WebRTC";
    mainProgram = "neko";
  };
}
