# llm-agents' orca with a working darwin launcher. Upstream links
# bin/orca-ide straight to Orca.app/Contents/MacOS/Orca; Electron then looks
# for its helper apps relative to the symlink and dies with "Unable to find
# helper app". Executing the binary by its real path inside the bundle works.
{
  stdenvNoCC,
  runtimeShell,
  fetchurl,
  llm-agents,
}:
let
  # stablyai deleted the v1.4.225 and v1.4.226 releases, so llm-agents' src 404s.
  version = "1.4.224";
  platforms = {
    x86_64-linux = {
      file = "orca-ide_${version}_amd64.deb";
      hash = "sha256-8Dolyl9dHc5Nl5uCOGXevEC0ikGYsbqAbR9KtXYHbAo=";
    };
    aarch64-linux = {
      file = "orca-ide_${version}_arm64.deb";
      hash = "sha256-89BqCDSQaJzTymaIHtJwfHj2MTTSptk5KEruAFov/NE=";
    };
    aarch64-darwin = {
      file = "Orca-${version}-arm64-mac.zip";
      hash = "sha256-3tqvPVAipAYnHA0JpL6l2jsXwu32DpGcfkqxKDrXqBQ=";
    };
  };
  platform = platforms.${stdenvNoCC.hostPlatform.system};
  pinned = llm-agents.orca.overrideAttrs {
    inherit version;
    src = fetchurl {
      url = "https://github.com/stablyai/orca/releases/download/v${version}/${platform.file}";
      inherit (platform) hash;
    };
  };
in
if stdenvNoCC.hostPlatform.isDarwin then
  pinned.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      rm $out/bin/orca-ide
      cat >$out/bin/orca-ide <<EOF
      #!${runtimeShell}
      exec "$out/Applications/Orca.app/Contents/MacOS/Orca" "\$@"
      EOF
      chmod +x $out/bin/orca-ide
    '';
  })
else
  pinned
