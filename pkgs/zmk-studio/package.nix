{
  lib,
  appimageTools,
  fetchurl,
  nix-update-script,
}:

let
  pname = "zmk-studio";
  version = "0.3.1";

  src = fetchurl {
    url = "https://github.com/zmkfirmware/zmk-studio/releases/download/v${version}/ZMK.Studio_${version}_amd64.AppImage";
    hash = "sha256-kDt3AxPV1901WH3n6+mmylLwnvRrAuHSlFlRK9qEoOs=";
  };

  appimageContents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--flake"
      "--system"
      "x86_64-linux"
    ];
  };

  extraInstallCommands = ''
    install -Dm444 "${appimageContents}/ZMK Studio.desktop" $out/share/applications/zmk-studio.desktop
    install -Dm444 ${appimageContents}/zmk-studio.png $out/share/icons/hicolor/128x128/apps/zmk-studio.png
  '';

  meta = {
    description = "Runtime keymap editor for ZMK keyboards";
    homepage = "https://zmk.studio/";
    downloadPage = "https://github.com/zmkfirmware/zmk-studio/releases";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "zmk-studio";
  };
}
