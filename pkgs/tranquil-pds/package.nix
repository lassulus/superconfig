{
  tranquil-pds,
  tranquil-pds-frontend,
  fetchFromTangled,
  rustPlatform,
}:
let
  version = "0.7.0";
  src = fetchFromTangled {
    did = "did:plc:jj6ajj6duxnlthwtnob4qyuv";
    tag = "v${version}";
    hash = "sha256-QbncR2z9GhxKKbbCf6a5Ph4lLi4OYWjRN49s7+5q7Uc=";
  };
in
tranquil-pds.overrideAttrs (
  finalAttrs: old: {
    inherit version src;
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-fjT0cAt7lPD0O2PGNT604dRIczerKjExJvU/L3Yul3c=";
    };
    passthru = old.passthru // {
      # web UI, served from settings.frontend.dir
      frontend = tranquil-pds-frontend.overrideAttrs (old: {
        inherit version src;
        pnpmDeps = old.pnpmDeps.overrideAttrs {
          inherit version src;
          outputHash = "sha256-+P4UUkZKQJVfGbDFKR0gRMU+wYK9K7NBYo1s/ebRK9I=";
        };
      });
    };
  }
)
