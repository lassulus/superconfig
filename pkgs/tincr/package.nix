{
  lib,
  rustPlatform,
  fetchFromGitHub,
  installShellFiles,
  pkg-config,
  openssl,
}:

rustPlatform.buildRustPackage {
  pname = "tincr";
  version = "0-unstable-2026-10-28";

  # Our fork's integration branch: upstream main + tunnel-address gate +
  # forgetting only the refused UDP address + clearing the fast-path address.
  src = fetchFromGitHub {
    owner = "Lassulus";
    repo = "tincr";
    rev = "b84b88b2b5e18d4ca326467e582d41ea98d5ec5c";
    hash = "sha256-MTxzkgMJaZSnV3nyl4CB40VdCiRwJNcxmF6NssgaL1M=";
  };

  cargoHash = "sha256-a5OSMPumZahV+HdOuRgIlnaZJz7C0uo+AtBepTIqYV0=";

  # Just the deployable bin crates; --workspace would pull tinc-ffi's cc.
  cargoBuildFlags = [
    "-p"
    "tincd"
    "-p"
    "tinc-tools"
  ];

  # netns tests need bwrap+userns the build sandbox lacks.
  doCheck = false;

  # The repo's .cargo/config.toml builds x86_64-linux for x86-64-v3 (AVX2),
  # which dies with SIGILL on pre-Haswell CPUs (icarus, shodan: Ivy Bridge).
  # An env RUSTFLAGS replaces those target rustflags (cargo doesn't merge
  # them): keep the frame pointers, drop the CPU floor. Same as upstream's
  # nix/tincd.nix baselineCpu; the AEAD is OpenSSL with runtime dispatch.
  env.RUSTFLAGS = "-C force-frame-pointers=yes";

  # tinc-crypto's ChaPoly backend links openssl-sys against system openssl.
  nativeBuildInputs = [
    installShellFiles
    pkg-config
  ];
  buildInputs = [ openssl ];

  postInstall = ''
    installManPage man/*.[0-9]
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Drop-in Rust rewrite of tinc 1.1 VPN (SPTPS-only, Ed25519)";
    homepage = "https://github.com/Mic92/tincr";
    license = lib.licenses.gpl2Plus;
    mainProgram = "tincd";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
