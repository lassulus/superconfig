# uniffi-bindgen-react-native's CLI, which moonlight-web-stream's frontend
# build uses to compile moonlight-common-rust to wasm. Its npm package only
# ships a launcher that `cargo run`s the CLI from source (without a
# Cargo.lock), so it is built here from the tag matching package-lock.json.
{
  rustPlatform,
  fetchFromGitHub,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "uniffi-bindgen-react-native";
  version = "0.31.0-6";

  src = fetchFromGitHub {
    owner = "jhugman";
    repo = "uniffi-bindgen-react-native";
    tag = finalAttrs.version;
    hash = "sha256-SEeNQ0IAFuDk1nDuu8WCKCKO5gPcxNHyv7i3PbCzbjM=";
  };

  cargoHash = "sha256-MlgP9C9y3bb9Nr2V5sR104v2wuyzsFudK/Ny+jGe0+Y=";

  cargoBuildFlags = [
    "-p"
    "uniffi-bindgen-react-native"
  ];
  doCheck = false;
})
