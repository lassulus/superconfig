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
  version = "0-unstable-2026-10-17";

  # Our fork's integration branch: upstream main + tunnel-address gate + the
  # UDP-blackhole-after-ENETUNREACH fix, until Mic92/tincr#140 lands.
  src = fetchFromGitHub {
    owner = "Lassulus";
    repo = "tincr";
    rev = "bfcbbc698a95b10843056852f7b1417083906915";
    hash = "sha256-T5bmAsYcCP06hdmgEE4fFdEH5uvXjAWLijdHNfg0fLw=";
  };

  cargoHash = "sha256-3kVlB537Oe1yvmMNoCnuNkBgYqxFLvnBbc97uKGmb3g=";

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
