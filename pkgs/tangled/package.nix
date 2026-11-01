{
  lib,
  rustPlatform,
  fetchgit,
  cmake,
  perl,
}:

# Tangled's knot 2 (knot-rs, https://tangled.org/tangled.org/core) without
# its flake, built with nixpkgs' rustPlatform instead of its crate2nix
# Cargo.nix. Only the knot: the web UI and the index (bobbin) are
# tangled.org's until a self-hosted frontend is supported.
rustPlatform.buildRustPackage {
  pname = "knot-server";
  version = "0-unstable-2026-11-01";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "7792426d56796a4e48b9878bcd40bb3c5df85f8c";
    hash = "sha256-XLnfgqYs8I1ttvbv3GzU1nshPmBLCwWmJgiV/fOdbGI=";
  };

  cargoHash = "sha256-jh8UaDLA4Z4QA98m7ikNc43DQN2LKL4aokbn32XUtpI=";
  nativeBuildInputs = [
    cmake
    perl
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
