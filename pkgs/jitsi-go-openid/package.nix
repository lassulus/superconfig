{
  lib,
  buildGoModule,
  fetchFromGitHub,
  nix-update-script,
}:

buildGoModule {
  pname = "jitsi-go-openid";
  version = "0-unstable-2026-10-09";

  src = fetchFromGitHub {
    owner = "mod242";
    repo = "jitsi-go-openid";
    rev = "3c798371cb14d9e5dfebc9152779d90911f3d0a2";
    hash = "sha256-zQr/bhHJDX7K+aHfTzsGoOBcmBC7YO8hWT8X26Xv0AA=";
  };

  patches = [ ./moderator.patch ];

  vendorHash = "sha256-Z7fX0GwSx1HVMPBQw8HR8DYL9LgYmq2S1aZLG7T92u8=";

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
