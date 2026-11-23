{
  lib,
  libgit2,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  installShellFiles,
  udev,
}:

# lassulus/passless age-backend: upstream passless plus a passage (age)
# storage backend. nixpkgs' passless (0.20.2) is too far behind to override.
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "passless";
  version = "0.27.3-unstable-2026-11-20";

  src = fetchFromGitHub {
    owner = "lassulus";
    repo = "passless";
    rev = "5bd1e0a0617dda5e693eddbde4f96a7963a5962a";
    hash = "sha256-XD/CXjBB2iZBX22gIKOgS2eOeSz8NRiEIr6Ne/VdZrI=";
  };

  cargoHash = "sha256-n75GmQKqqLcIjMardMQKztJycoMaUjREKpFbGQjJN9c=";

  # only the daemon/client crate, not the workspace's dev tools
  cargoBuildFlags = [
    "-p"
    "passless-rs"
  ];
  cargoTestFlags = finalAttrs.cargoBuildFlags;
  checkFlags = [
    # runs the passless-git-sync helper next to the test binary, which
    # cargo's deps dir lacks
    "--skip=storage::pass::sync::tests::commit_only_mode_never_pushes_to_remote"
  ];

  nativeBuildInputs = [
    pkg-config
    installShellFiles
  ];

  buildInputs = [
    libgit2
    udev
  ];

  postInstall = ''
    install -Dm644 -t $out/etc/udev/rules.d contrib/udev/*
    completions=$(echo target/*/$cargoBuildType/build/passless-rs-*/out/completions)
    installShellCompletion --cmd passless \
      --bash $completions/passless.bash \
      --fish $completions/passless.fish \
      --zsh $completions/_passless
  '';

  meta = {
    description = "Virtual FIDO2 device storing passkeys in pass/passage (lassulus age-backend fork)";
    homepage = "https://github.com/lassulus/passless/tree/age-backend";
    license = lib.licenses.gpl3Only;
    mainProgram = "passless";
    platforms = lib.platforms.linux;
  };
})
