{
  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (
        ps: with ps; [
          astropy
          numpy
          pillow
        ]
      );
      constellations = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/ofrohn/d3-celestial/7e720a3de062059d4c5400a379146a601d9010e0/data/constellations.lines.json";
        hash = "sha256-KU9mvvXVz1Cx4X8W0u+h2XoVExYSxo3ZNa3vbnNz4Tw=";
      };
      krebsIcon =
        pkgs.runCommand "krebs.png"
          {
            nativeBuildInputs = [ pkgs.librsvg ];
            src = pkgs.fetchurl {
              url = "https://raw.githubusercontent.com/krebs/painload/25bb340f4d8d05bb3ab6792277951b77923e7010/cholerab/bling/krebs_aquarium.svg";
              hash = "sha256-KLoY58M3bPcI0WrqomPbDNewKz+akeR0oujccDeUqnY=";
            };
          }
          ''
            rsvg-convert -w 64 -h 64 "$src" -o "$out"
          '';
    in
    {
      packages.realwallpaper =
        (pkgs.writeShellApplication {
          name = "realwallpaper";
          runtimeInputs = [ python ];
          text = ''
            export REALWALLPAPER_CONSTELLATIONS=${constellations}
            export REALWALLPAPER_KREBS_ICON=${krebsIcon}
            export REALWALLPAPER_FONT=${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf
            exec python3 ${./realwallpaper.py} "$@"
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
