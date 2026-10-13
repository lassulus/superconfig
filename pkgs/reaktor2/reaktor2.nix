{
  mkDerivation,
  aeson,
  async,
  attoparsec,
  base,
  base64,
  blessings,
  bytestring,
  containers,
  data-default,
  directory,
  fetchgit,
  filepath,
  hashable,
  http-types,
  lens,
  lens-aeson,
  lib,
  network,
  network-simple,
  network-simple-tls,
  network-uri,
  pcre-light,
  process,
  random,
  servant-server,
  string-conversions,
  stringsearch,
  text,
  time,
  transformers,
  unagi-chan,
  unix,
  unordered-containers,
  vector,
  wai,
  warp,
}:
mkDerivation {
  pname = "reaktor2";
  version = "0.4.5";
  src = fetchgit {
    url = "https://cgit.krebsco.de/reaktor2";
    sha256 = "0arcw06k3hhmcp6kk5lxrzadin3lx6ywxrznicljr92flkgj8isc";
    rev = "6ff1335c7c9775e1cf167b950b6de97359d3b659";
    fetchSubmodules = true;
  };
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson
    async
    attoparsec
    base
    base64
    blessings
    bytestring
    containers
    data-default
    directory
    filepath
    hashable
    http-types
    lens
    lens-aeson
    network
    network-simple
    network-simple-tls
    network-uri
    pcre-light
    process
    random
    servant-server
    string-conversions
    stringsearch
    text
    time
    transformers
    unagi-chan
    unix
    unordered-containers
    vector
    wai
    warp
  ];
  license = lib.licenses.mit;
  mainProgram = "reaktor";
  passthru.updateScript = ./update.sh;
}
