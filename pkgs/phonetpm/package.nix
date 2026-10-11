{
  lib,
  rustPlatform,
  fetchFromGitHub,
}:

rustPlatform.buildRustPackage rec {
  pname = "phonetpm";
  version = "0.4.1";

  src = fetchFromGitHub {
    owner = "Lassulus";
    repo = "phonetpm";
    tag = "v${version}";
    hash = "sha256-K8R0lEMQ9ZjoRlMKpLEAH3qriQ5VyrOXkVuYI+J7nBY=";
  };

  cargoHash = "sha256-pTgkA+jc+G8GxiDsVHP5q9Zt55k1nyr1ltAAqRXEpqc=";

  # Host side only: `phonetpm` (daemon/pair/keys) and `age-plugin-phone`.
  # The workspace also holds the Android core (uniffi cdylib), not needed here.
  cargoBuildFlags = [
    "-p"
    "phonetpm"
  ];
  cargoTestFlags = cargoBuildFlags;

  meta = {
    description = "Android phone as a biometric ssh-agent and age backend over iroh";
    homepage = "https://github.com/Lassulus/phonetpm";
    license = lib.licenses.mit;
    mainProgram = "phonetpm";
    platforms = lib.platforms.linux;
  };
}
