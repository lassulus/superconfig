{
  lib,
  rustPlatform,
  fetchFromGitHub,
  fetchNpmDeps,
  callPackage,
  symlinkJoin,
  nodejs_26,
  npmHooks,
  wasm-bindgen-cli_0_2_128,
  lld,
  makeWrapper,
  pkg-config,
  zstd,
  nix-update-script,
}:
let
  ubrn = callPackage ./ubrn.nix { };

  # The frontend's moonlight-common-rust, which `npm run build` would clone
  # with `ubrn checkout`: the rev of ubrn.config.yaml (and of Cargo.lock).
  moonlightCommon = fetchFromGitHub {
    owner = "MrCreativ3001";
    repo = "moonlight-common-rust";
    rev = "a972937b2e84b21a6a390873930e3afe4cfa767d";
    hash = "sha256-itOCsQ061cfnmX4heOMOIVFSQi2uJbCL9ph0rW4cfPg=";
  };

  # Crates for ubrn's two cargo builds: the bindings crate (native, in the
  # moonlight-common-rust workspace) and the wasm crate ubrn generates in
  # rust_modules/wasm. That crate has no lock upstream; wasm-Cargo.lock is
  # the one cargo resolves for it (regenerate it on updates).
  frontendCargoDeps = symlinkJoin {
    name = "moonlight-web-stream-frontend-vendor";
    paths = [
      "${
        rustPlatform.fetchCargoVendor {
          name = "moonlight-common-rust";
          src = moonlightCommon;
          hash = "sha256-+AGKKWGz0BWZ8OX/wshJWcq47bKHOISglwG5ddbY6KI=";
        }
      }/source-registry-0"
      (rustPlatform.importCargoLock { lockFile = ./wasm-Cargo.lock; })
    ];
  };
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "moonlight-web-stream";
  version = "3.0.1";

  src = fetchFromGitHub {
    owner = "MrCreativ3001";
    repo = "moonlight-web-stream";
    tag = "v${finalAttrs.version}";
    hash = "sha256-0TLTSUm5bOrauaKwvW7lvnT1QY2poRsLGZVXdUJjIaQ=";
  };

  cargoHash = "sha256-deoJfH/8CbmPCh1Jf4XETKxhncgF1UZdKuXi7tk7kn4=";

  npmDeps = fetchNpmDeps {
    inherit (finalAttrs) src;
    hash = "sha256-sUxfnPsvDrzvfTJ2vCJUvFCX1mIzwCsbvG+BSFVUQog=";
  };

  nativeBuildInputs = [
    nodejs_26
    npmHooks.npmConfigHook
    ubrn
    wasm-bindgen-cli_0_2_128
    lld
    makeWrapper
    pkg-config
  ];

  # actix-web's zstd compression
  buildInputs = [ zstd ];

  # `npm run build` without its network steps: the TypeScript API bindings
  # (ts-rs, written by the export_bindings tests), moonlight-common-rust as
  # wasm (ubrn), then webpack into dist.
  postBuild = ''
    cargo test --release --offline export_bindings

    mkdir -p rust_modules/wasm
    cp -r --no-preserve=mode ${moonlightCommon} rust_modules/moonlight-common-rust
    cp ${./wasm-Cargo.lock} rust_modules/wasm/Cargo.lock
    # ubrn's cargo runs (from here and from rust_modules) use the frontend's
    # crates: this config overrides the one cargoSetupHook put in the parent
    # directory, until the checkPhase needs that one again.
    mkdir .cargo
    cat > .cargo/config.toml <<EOF
    [source.crates-io]
    replace-with = "frontend-vendored-sources"
    [source.frontend-vendored-sources]
    directory = "${frontendCargoDeps}"
    EOF
    uniffi-bindgen-react-native build web
    rm -r .cargo

    node_modules/.bin/webpack --mode=production
  '';

  postInstall = ''
    mkdir -p $out/share/moonlight-web-stream
    cp -r dist $out/share/moonlight-web-stream/static
    # web-server serves ./static
    wrapProgram $out/bin/web-server --chdir $out/share/moonlight-web-stream
  '';

  passthru.updateScript = nix-update-script { extraArgs = [ "--flake" ]; };

  meta = {
    description = "Web client for Sunshine: streams through WebRTC or WebSockets into a browser";
    homepage = "https://github.com/MrCreativ3001/moonlight-web-stream";
    license = lib.licenses.gpl3Plus;
    mainProgram = "web-server";
    platforms = lib.platforms.linux;
  };
})
