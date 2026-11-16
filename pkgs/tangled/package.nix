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
  version = "0-unstable-2026-11-15";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "cff614dedaa51c63bcf874a2a9d49e2f3fe188d5";
    hash = "sha256-mpXdZOIHrmz9AuI1Uu14d5D6J6MAio74YI1NUg9WJ1w=";
  };

  cargoHash = "sha256-Iw3tksIqXl4yNs8c9HeyZLQQ7/KLxIrNseXmC4UtCdE=";
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
