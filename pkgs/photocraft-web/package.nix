{
  lib,
  rustPlatform,
  fetchFromGitHub,
  fetchCrate,
  buildWasmBindgenCli,
  trunk,
  binaryen,
  llvmPackages,
}:

let
  # trunk refuses to run a wasm-bindgen whose version differs from the one in
  # Cargo.lock, and nixpkgs only ships up to 0.2.127.
  wasm-bindgen-cli = buildWasmBindgenCli rec {
    src = fetchCrate {
      pname = "wasm-bindgen-cli";
      version = "0.2.129";
      hash = "sha256-pcecKQd7E8Opw6bkFoE569epUi7gh5qpQF1e5PJY6V8=";
    };

    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit src;
      inherit (src) pname version;
      hash = "sha256-vmUrWVU7kPJJxO5qIVeAkwQyWDELO1Z4Z5gitz2kco8=";
    };
  };
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "photocraft-web";
  version = "0.8.2";

  src = fetchFromGitHub {
    owner = "storytold";
    repo = "photocraft";
    tag = "v${finalAttrs.version}";
    hash = "sha256-kqKpZ8IBPmCd93XXvyxyAjPjJEWFfZh49qQc9KMSp4Y=";
  };

  cargoHash = "sha256-dafKVsoBYuChW0nsjUhk5GqCChAO07A4Rhhv2UAdEx0=";

  nativeBuildInputs = [
    trunk
    wasm-bindgen-cli
    binaryen
    llvmPackages.bintools-unwrapped
  ];

  # Shown in Help › About (crates/engine/src/build_info.rs).
  env.PHOTOCRAFT_BUILD_SHA = finalAttrs.src.tag;

  buildPhase = ''
    runHook preBuild
    (cd apps/photocraft-web && HOME=$TMPDIR trunk build --offline --frozen --release)
    runHook postBuild
  '';

  # The test suite targets the native workspace, not the wasm bundle.
  doCheck = false;

  installPhase = ''
    runHook preInstall
    cp -r dist/web $out
    runHook postInstall
  '';

  passthru = {
    inherit wasm-bindgen-cli;
    updateScript = ./update.sh;
  };

  meta = {
    description = "PhotoCraft image editor compiled to WebAssembly, as a static site";
    homepage = "https://getartcraft.com/apps/photocraft";
    license = with lib.licenses; [
      mit
      asl20
    ];
    platforms = lib.platforms.all;
  };
})
