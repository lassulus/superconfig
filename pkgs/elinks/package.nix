# Replacement for nixpkgs's `elinks`, switched to the meson build from
# upstream nixpkgs PR #515347 (https://github.com/NixOS/nixpkgs/pull/515347).
#
# nixpkgs's autotools build of elinks 0.19.1 is broken against gettext
# 0.23.1 (autopoint refuses `AM_GNU_GETTEXT` without an `external`
# argument; further, autoheader then fails on `HAVE_ALLOCA`). The PR
# sidesteps autotools entirely. We carry it locally until it lands.
#
# The PR also moves a few entries from `buildInputs` to
# `propagatedBuildInputs` on libcss and libdom so they're picked up
# transitively. Rather than overlaying those packages globally, we
# tweak them inline here (only this elinks build sees the change).
{
  lib,
  stdenv,
  fetchFromGitHub,
  ncurses,
  bzip2,
  zlib,
  brotli,
  zstd,
  xz,
  openssl,
  meson,
  ninja,
  gettext,
  python3,
  perl,
  pkg-config,
  xmlto,
  docbook_xml_dtd_42,
  gpm,
  libidn2,
  tre,
  expat,
  lua,
  curl,
  libcss,
  libdom,
  libparserutils,
  libwapcaplet,
  libhubbub,
  enableGuile ? false,
  guile ? null,
  enablePython ? false,
  python ? null,
  enablePerl ? (!stdenv.hostPlatform.isDarwin) && (stdenv.hostPlatform == stdenv.buildPlatform),
  nix-update-script,
}:

let
  # libcss with libparserutils/libwapcaplet propagated, so meson's
  # pkg-config lookup finds them when elinks links against libcss.
  libcss' = libcss.overrideAttrs (old: {
    buildInputs = lib.filter (d: d != libparserutils && d != libwapcaplet) (old.buildInputs or [ ]);
    propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
      libparserutils
      libwapcaplet
    ];
  });

  # libdom: libhubbub/libwapcaplet propagated, for the same reason.
  libdom' = libdom.overrideAttrs (old: {
    buildInputs = lib.filter (d: d != libhubbub && d != libwapcaplet) (old.buildInputs or [ ]);
    propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
      libhubbub
      libwapcaplet
    ];
  });
in
stdenv.mkDerivation (finalAttrs: {
  pname = "elinks";
  version = "0.20.0";

  src = fetchFromGitHub {
    owner = "rkd77";
    repo = "elinks";
    rev = "v${finalAttrs.version}";
    hash = "sha256-oh9nArQ8dkYL4fLSjnnCHbSnxNxJnQmAWD/6Nu7OiiQ=";
  };

  outputs = [
    "out"
    "man"
    "doc"
  ];

  buildInputs = [
    ncurses
    bzip2
    zlib
    brotli
    zstd
    xz
    openssl
    libidn2
    tre
    expat
    lua
    curl
    libcss'
    libdom'
  ]
  ++ lib.optional stdenv.hostPlatform.isDarwin gettext
  ++ lib.optional enableGuile guile
  ++ lib.optional enablePython python
  ++ lib.optional enablePerl perl;

  nativeBuildInputs = [
    meson
    ninja
    gettext
    perl
    python3
    pkg-config
    xmlto
  ];

  env =
    lib.optionalAttrs stdenv.hostPlatform.isLinux {
      C_INCLUDE_PATH = "${lib.getInclude gpm}/include";
      LIBRARY_PATH = "${lib.getLib gpm}/lib";
    }
    // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
      LDFLAGS = "-liconv";
    };

  strictDeps = true;
  __structuredAttrs = true;

  mesonFlags =
    (map (f: lib.mesonBool f true) [
      "finger"
      "html-highlight"
      "gopher"
      "gemini"
      "cgi"
      "nntp"
      "256-colors"
      "true-color"
      "brotli"
      "lzma"
      "terminfo"
      "reproducible"
    ])
    ++ [
      (lib.mesonOption "luapkg" "lua")
      (lib.mesonBool "gpm" stdenv.hostPlatform.isLinux)
      (lib.mesonBool "guile" enableGuile)
      (lib.mesonBool "python" enablePython)
      (lib.mesonBool "perl" enablePerl)
    ];

  postPatch = ''
    patchShebangs doc/tools
    substituteInPlace doc/tools/asciidoc/docbook.conf \
      --replace-fail "http://www.oasis-open.org/docbook/xml/4.2/docbookx.dtd" "${docbook_xml_dtd_42}/xml/dtd/docbook/docbookx.dtd"
  '';

  preConfigure = ''
    mesonFlags+=("-Dsource-date-epoch=$SOURCE_DATE_EPOCH")
  '';

  passthru.updateScript = nix-update-script { extraArgs = [ "--flake" ]; };

  meta = {
    description = "Full-featured text-mode web browser (meson build, PR #515347)";
    mainProgram = "elinks";
    homepage = "https://github.com/rkd77/elinks";
    license = lib.licenses.gpl2Only;
    platforms = with lib.platforms; linux ++ darwin;
  };
})
