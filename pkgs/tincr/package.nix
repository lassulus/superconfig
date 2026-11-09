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
  version = "0-unstable-2026-11-08";

  src = fetchFromGitHub {
    owner = "Mic92";
    repo = "tincr";
    rev = "07c455524c55a40819da3fb75ee1cf72c4cb96cb";
    hash = "sha256-Uh+haWoIh/yl1Z+k1GRHR7fFewXDCQcVUV7xIlf8bdU=";
  };

  cargoHash = "sha256-fXW+8t4QuD1cuHjI9t6B/fCvmYYWgPdFz5iLnr/3JSo=";

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
