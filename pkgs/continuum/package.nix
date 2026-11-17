{
  lib,
  rustPlatform,
  fetchgit,
  fetchurl,
  pkg-config,
  openssl,
  zstd,
  sqlite,
}:
rustPlatform.buildRustPackage {
  pname = "continuum";
  version = "1.0.0-unstable-2026-11-17";

  src = fetchgit {
    url = "https://cgit.krebsco.de/continuum";
    rev = "393fb4d70fc6bf88debc4ca13d644ea7de9602f5";
    hash = "sha256-QZg8TyFdIxzqZJUHsrnyoukQpw9RmMej8etNWqbzpTk=";
  };

  # ECDSA party keys and ssh-agent signing, not upstream yet
  patches = [ ./ecdsa-keys.patch ];

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

  buildNoDefaultFeatures = true;
  buildFeatures = [
    "tor"
    "federation"
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
