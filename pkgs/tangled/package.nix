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
  version = "0-unstable-2026-11-02";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "637e8648382701e0e57ed3b07f93710d7c520ac5";
    hash = "sha256-XDuxyZC/kE+0n63D6R+2lHba3eeQISD60/GP0Wbb7EE=";
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
