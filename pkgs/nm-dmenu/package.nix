{ pkgs, lib, ... }:

let
  meta.platforms = lib.platforms.linux;
in
# The writer forces the script at eval time and rofi & co. refuse to evaluate
# off Linux, so reference them only there and keep meta readable elsewhere.
if pkgs.stdenv.hostPlatform.isLinux then
  (pkgs.writers.writeDashBin "nm-dmenu" ''
    export PATH=$PATH:${
      lib.makeBinPath [
        (pkgs.writers.writeDashBin "dmenu" ''
          exec ${lib.getExe pkgs.rofi} -dmenu "$@"
        '')
        pkgs.networkmanagerapplet
        pkgs.procps
      ]
    }
    exec ${pkgs.networkmanager_dmenu}/bin/networkmanager_dmenu "$@"
  '')
  // {
    inherit meta;
  }
else
  pkgs.runCommand "nm-dmenu" { inherit meta; } ""
