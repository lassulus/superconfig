{
  lib,
  rustPlatform,
  fetchFromGitHub,
  installShellFiles,
  pkg-config,
  openssl,
}:
let
  src = fetchFromGitHub {
    owner = "Mic92";
    repo = "tincr";
    rev = "fd92f2164f8f4e2927d6c983a116bf41ac2337d5";
    hash = "sha256-dT/Ny0jbVMeeW1TGp/YDPQGiDwspvhd8/k/OgULz57Y=";
  };

  # Reads the pinned source at eval time (a locked fetch, no IFD). Skipped
  # while update.sh has the hash blanked to probe for the new one.
  srcHas =
    file: needle:
    src.outputHash != lib.fakeHash
    && lib.hasInfix needle (
      builtins.readFile "${
        builtins.fetchTree {
          type = "github";
          inherit (src) owner repo rev;
          narHash = src.outputHash;
        }
      }/${file}"
    );
in
# Releases a seen UDP address whose probes go unanswered, so a flushed NAT
# mapping no longer keeps both ends on a relayed path (Mic92/tincr#184).
lib.throwIf (srcHas "crates/tincd/src/udp_path.rs" "fn release_unanswered_seen(")
  "pkgs/tincr: the pinned tincr has release_unanswered_seen, remove release-unanswered-seen.patch"
  # Announces a direct peer's NAT-mapped UDP port in our edge, so a pair
  # relayed elsewhere finds it again after the NAT rebinds (radio <-> styx).
  lib.throwIf
  (srcHas "crates/tincd/src/daemon/gossip/send.rs" "fn advertise_udp_edge_addr(")
  "pkgs/tincr: the pinned tincr has advertise_udp_edge_addr, remove advertise-nat-udp-port.patch"
  rustPlatform.buildRustPackage
  {
    pname = "tincr";
    version = "0-unstable-2026-11-17";

    inherit src;

    patches = [
      ./release-unanswered-seen.patch
      ./advertise-nat-udp-port.patch
    ];

    cargoHash = "sha256-GZBCoFmtnhm3VqoMxIPl0+STJmz33pPsS+fgU7ic+D4=";

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
