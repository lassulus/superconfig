{ vector }:
# vector 0.59.0 against the current rustc:
# - #![deny(warnings)] turns the deprecation of Atomic::fetch_update into an
#   error in vector-common. Downgrade the lint to warn, as nixpkgs does
#   since vector 0.60.0 (NixOS/nixpkgs#576203).
# - deserialization_json compares against the old wording of std's integer
#   conversion error ("out of range integral type conversion attempted").
# Drop this package once our nixpkgs pin includes vector 0.60.0, which
# builds without tests.
vector.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    sed -i 's/#!\[deny(warnings)]/#!\[warn(warnings)]/' lib/*/src/lib.rs src/lib.rs src/main.rs vdev/src/main.rs
  '';
  checkFlags = old.checkFlags ++ [
    "--skip=sinks::util::buffer::compression::test::deserialization_json"
  ];
})
