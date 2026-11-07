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
  version = "0-unstable-2026-11-07";

  src = fetchgit {
    url = "https://tangled.org/tangled.org/core";
    rev = "6149fd1cfce64003ca9ffdbbb1c0c65449c24a52";
    hash = "sha256-wLloeEH66HGZYvpjqPhINuR83VefcD95r9QrUYQXd5Q=";
  };

  cargoHash = "sha256-jZVbyGohaoZYytg+Z0ZpmXjd9xtr5KoeC41mVhBP378=";
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
