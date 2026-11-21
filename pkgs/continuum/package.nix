{
  lib,
  rustPlatform,
  fetchgit,
  fetchurl,
  pkg-config,
  openssl,
  zstd,
  sqlite,
  openssh,
}:
rustPlatform.buildRustPackage {
  pname = "continuum";
  version = "1.0.0-unstable-2026-11-19";

  src = fetchgit {
    url = "https://cgit.krebsco.de/continuum";
    rev = "10786d2e598865cd6e763df08f692cfc0f756908";
    hash = "sha256-jq8kkb6wSO6Kd2EBq9WhCCkByOX27tb23fY57skIZGo=";
  };

  # upstream has no Cargo.lock
  cargoLock.lockFile = ./Cargo.lock;
  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
  '';

  # arti (the tor feature) links openssl, sqlite and zstd
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    openssl
    sqlite
    zstd
  ];

  # the key tests sign through ssh-agent and check with ssh-keygen, and fail without them
  nativeCheckInputs = [ openssh ];

  buildNoDefaultFeatures = true;
  buildFeatures = [
    "tor"
    "federation"
    "dashboard"
  ];

  # utoipa-swagger-ui downloads the Swagger UI in its build script otherwise
  env.SWAGGER_UI_DOWNLOAD_URL = "file://${
    fetchurl {
      url = "https://github.com/swagger-api/swagger-ui/archive/refs/tags/v5.32.6.zip";
      hash = "sha256-s8B+CRVZtZqDP2ZUfrH8GPKJb5bj8flT4vHvsyiqM5Q=";
    }
  }";

  # the simulations run whole swarms in real time
  checkFlags = [
    "--skip"
    "simtest"
  ];

  # the test build reruns that build script, which copies the zip over its read-only copy
  preCheck = ''
    find target -path '*utoipa-swagger-ui*' -name '*.zip' -exec chmod u+w {} +
  '';

  passthru.updateScript = ./update.sh;

  meta = {
    description = "Replicated Automerge document over P2P transports, with federations of parties";
    homepage = "https://cgit.krebsco.de/continuum";
    platforms = lib.platforms.linux;
    mainProgram = "continuum";
  };
}
