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
    rev = "0ca484020863de771f60c42c2c07ce133768206e";
    hash = "sha256-MvjyNCRypo9GxARFXVCfSMRf1dye8xFGklxYcypVfFI=";
  };

  cargoHash = "sha256-cm4kJ4nrdAs7U2Zp+3NCDWSp8MOgPb/9TOn9D3QBnGM=";
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
