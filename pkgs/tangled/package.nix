{
  lib,
  rustPlatform,
  fetchgit,
  cmake,
  perl,
  pkg-config,
  aws-lc,
  rust-jemalloc-sys,
  sqlite,
  zstd,
}:

# Tangled's knot 2 (knot-rs, https://tangled.org/tangled.org/core) without
# its flake, built with nixpkgs' rustPlatform instead of its crate2nix
# Cargo.nix. Only the knot: the web UI and the index (bobbin) are
# tangled.org's until a self-hosted frontend is supported.
rustPlatform.buildRustPackage {
  pname = "knot-server";
  version = "0-unstable-2026-11-24";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "062e1a1a2658feca4bc75324edb57ab134689aea";
    hash = "sha256-tg5PvcPC+y1lDGi42otr4J4a3nwrnNE200mpwud28ns=";
  };

  cargoHash = "sha256-x2t+YYQ3mc1Tz+lqXJvH/TuE8o5aKrpoIvt6N7JpC+M=";
  nativeBuildInputs = [
    cmake
    perl
    pkg-config
  ];
  buildInputs = [
    aws-lc
    rust-jemalloc-sys
    sqlite
    zstd
  ];
  dontUseCmakeConfigure = true;
  cargoBuildFlags = [
    "--bin"
    "knot-server"
    "--package"
    "knot-server"
  ];
  doCheck = false;

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Tangled's git server (knot 2)";
    homepage = "https://tangled.org/tangled.org/core";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "knot-server";
  };
}
