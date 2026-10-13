{
  mkDerivation,
  base,
  bytestring,
  extra,
  fetchgit,
  hspec,
  lib,
  mono-traversable,
  QuickCheck,
  text,
  wcwidth,
}:
mkDerivation {
  pname = "blessings";
  version = "2.6.0";
  src = fetchgit {
    url = "https://cgit.krebsco.de/blessings";
    sha256 = "sha256-UO1DP6MbKfypKNRUyRfnksaeawje9nUkVZU3ApzIEhI=";
    rev = "35854c8df0c97ad99325f1bf3837d1e7efdaf21e";
    fetchSubmodules = true;
  };
  libraryHaskellDepends = [
    base
    bytestring
    extra
    mono-traversable
    text
    wcwidth
  ];
  testHaskellDepends = [
    base
    hspec
    QuickCheck
  ];
  license = lib.licenses.mit;
}
