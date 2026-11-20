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
  version = "0-unstable-2026-11-19";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "f67fce52136294d0d7c34357481d1185b7d232e8";
    hash = "sha256-vo577EJLAed/JOiG8GxrbfrezioigyywDTHYylf4s80=";
  };

  cargoHash = "sha256-2Tr1cML1uWMkrgDFa3mGylKr5UCDv1TsCkhAnLxxs4U=";
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
