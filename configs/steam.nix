{ pkgs, lib, ... }:

{
  # fixed in nixpkgs' steam module, opened by remotePlay and dedicatedServer
  lass.ports = lib.genAttrs (map toString (
    [
      10400
      10401
      27015
      27036
      27037
    ]
    ++ lib.range 27031 27035
  )) (port: "steam-${port}");

  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    package = pkgs.steam.override {
      extraPkgs = (
        pkgs: with pkgs; [
          gamemode
          xorg.libXcursor
          xorg.libXi
          xorg.libXinerama
          xorg.libXScrnSaver
          libpng
          libpulseaudio
          libvorbis
          stdenv.cc.cc.lib
          libkrb5
          keyutils
          # additional packages...
          # e.g. some games require python3
        ]
      );
      # extraLibraries = pkgs: [ pkgs.gperftools ];
      # - Automatically enable gamemode whenever Steam is running
      # -- NOTE: Assumes that a working system install of gamemode already exists!
      extraProfile =
        let
          gmLib = "${lib.getLib (pkgs.gamemode)}/lib";
        in
        ''
          export LD_LIBRARY_PATH="${gmLib}:$LD_LIBRARY_PATH"
          export PATH="${pkgs.gamescope}/bin:$PATH"
          # xpadneo owns the hidraw node; force SDL to use evdev for Xbox pads
          export SDL_JOYSTICK_HIDAPI_XBOX=0
        '';
    };
  };

  environment.systemPackages = with pkgs; [
    mangohud
    gamescope
  ];

  programs.gamemode.enable = true;
}
