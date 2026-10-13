# Copied from stockholm krebs/5pkgs/simple/grib2json (cc283503).
{
  stdenv,
  fetchzip,
  jre,
}:

stdenv.mkDerivation {
  name = "grib2json";
  src = fetchzip {
    url = "https://github.com/krebs/grib2json-bin/archive/31efe677b40fe491c988d50f96b59b1b7e2d46f7.zip";
    hash = "sha256-yyijh5SQ0nMZqox8lweIwVKLHNl6aazmYWovcMTrfsA=";
  };
  installPhase = ''
    mkdir -p $out/bin
    cp -r lib $out/
    cat > $out/bin/grib2json << EOF
    #!/bin/sh
    set -x
    ${jre}/bin/java -jar $out/lib/grib2json-0.8.0-SNAPSHOT.jar "\$@"
    EOF
    chmod +x $out/bin/grib2json
  '';
}
