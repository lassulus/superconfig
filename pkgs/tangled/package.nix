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
  version = "0-unstable-2026-11-10";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "a490a5958a17770b677bc48b69cf0e44fa579f63";
    hash = "sha256-UrhR4Z4CgOaEK2SgGNOLbhlWpO1Msh1YzbdYYNAfJIQ=";
  };

  cargoHash = "sha256-+8FgEXrYmyxE9f/N++FkjeoNc4zsm4HKLVMpRK4unHw=";
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
