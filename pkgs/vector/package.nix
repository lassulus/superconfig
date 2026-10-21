{ vector }:
# vector 0.59.0 against the current rustc:
# - #![deny(warnings)] turns the deprecation of Atomic::fetch_update into an
#   error in vector-common. Downgrade the lint to warn, as nixpkgs does
#   since vector 0.60.0 (NixOS/nixpkgs#576203).
# - The debug build of the test crate gets OOM-killed. Skip the tests, as
#   nixpkgs does since vector 0.60.0.
# Drop this package once our nixpkgs pin includes vector 0.60.0.
vector.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    sed -i 's/#!\[deny(warnings)]/#!\[warn(warnings)]/' lib/*/src/lib.rs src/lib.rs src/main.rs vdev/src/main.rs
  '';
  doCheck = false;
})
