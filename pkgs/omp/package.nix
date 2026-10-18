# nixpkgs' omp at the version of nixpkgs master (18.11.2).
{
  lib,
  omp,
  fetchFromGitHub,
  rustPlatform,
}:
assert lib.assertMsg (
  omp.version == "18.11.0"
) "nixpkgs has omp ${omp.version} now; drop pkgs/omp and use pkgs.omp again";
omp.overrideAttrs (
  finalAttrs: _: {
    version = "18.11.2";

    src = fetchFromGitHub {
      owner = "can1357";
      repo = "oh-my-pi";
      tag = "v${finalAttrs.version}";
      hash = "sha256-PJbclp6GbOtIFkIVXQaJYlF63ArcqHgzlRLolrzXNDI=";
    };

    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      hash = "sha256-2gnzA/DyvVHErgYoz8ORH29Oul1xxa2msH4/VAD3Aa4=";
    };
  }
)
