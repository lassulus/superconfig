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
  version = "0-unstable-2026-11-04";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "e70f5fce85a442529dff33beb66e83c0af1a51f2";
    hash = "sha256-mpQadf8V1jkLlWsJxd/r+Z0cW+U9YlJAzUkH3zoxVf8=";
  };

  cargoHash = "sha256-xrFS9bHytj25+Rxx5BPCQOdR2iAbwNqAToPJto2qbxk=";
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
