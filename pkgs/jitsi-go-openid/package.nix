{
  lib,
  buildGoModule,
  fetchFromGitHub,
  nix-update-script,
}:

buildGoModule {
  pname = "jitsi-go-openid";
  version = "1.3-unstable-2026-11-20";

  src = fetchFromGitHub {
    owner = "mod242";
    repo = "jitsi-go-openid";
    rev = "f071ad3e85cb3d53818b86e1941a0576cb248d2c";
    hash = "sha256-GId7PlnxP8P4GAAxdAM87o1Np3GL8OAXjzFekiKgF7U=";
  };

  patches = [ ./moderator.patch ];

  vendorHash = "sha256-dt0dBBNFSrgl5arGA+Mec5GWBnd0Dv6MhAlh/WC4FnQ=";

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--version=branch"
    ];
  };

  meta = {
    description = "OpenID Connect login for Jitsi Meet, issuing Jitsi JWTs";
    homepage = "https://github.com/mod242/jitsi-go-openid";
    license = lib.licenses.mit;
    mainProgram = "jitsi-go-openid";
    platforms = lib.platforms.linux;
  };
}
