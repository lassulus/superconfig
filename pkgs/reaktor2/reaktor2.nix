{
  mkDerivation,
  aeson,
  array,
  async,
  attoparsec,
  base,
  base64,
  blessings,
  bytestring,
  containers,
  data-default,
  directory,
  fetchFromGitHub,
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
  process,
  random,
  regex-base,
  regex-pcre2,
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
  src = fetchFromGitHub {
    owner = "krebs";
    repo = "reaktor2";
    rev = "6c94909eaa0fbaa3409ed1d713c649fcabfd90ef";
    hash = "sha256-UtFEOYoG6NOwk41+kGQBpdDTpOSnolOIMCZPEMpWlL0=";
  };
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson
    array
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
    process
    random
    regex-base
    regex-pcre2
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
