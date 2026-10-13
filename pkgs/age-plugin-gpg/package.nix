{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  nettle,
  nix-update-script,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "age-plugin-gpg";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "CertainLach";
    repo = "age-plugin-gpg";
    rev = "v${finalAttrs.version}";
    hash = "sha256-HfCl+YAjKPNFtLAHjNyjlHhRxD85qZLWsfKzqORtj5U=";
  };

  # Encrypt to keys that are only in the gpg keyring (no secret key or
  # smartcard stub in gpg-agent), e.g. on hosts generating clan vars.
  patches = [ ./keyring-fallback.patch ];

  cargoLock = {
    lockFile = "${finalAttrs.src}/Cargo.lock";
  };

  nativeBuildInputs = [
    pkg-config
    rustPlatform.bindgenHook
  ];

  buildInputs = [ nettle ];

  passthru.updateScript = nix-update-script { extraArgs = [ "--flake" ]; };

  meta = {
    description = "Age plugin utilizing gpg-agent & keygrips as recipients/identities";
    homepage = "https://github.com/CertainLach/age-plugin-gpg";
    license = lib.licenses.mit;
    mainProgram = "age-plugin-gpg";
    platforms = lib.platforms.unix;
    maintainers = [ ];
  };
})
