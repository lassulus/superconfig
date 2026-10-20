{ audacity }:
# audacity 4.0.0 fails against Qt 6.12 in the unity build of
# muse_extensions_qml: its qmlcachegen output lands in one translation unit
# with the module's mocs, and "reference to 'Type' is ambiguous" there.
# Build that one target without unity; the whole project can't, other
# modules rely on it for their includes. Drop this package once nixpkgs'
# audacity builds again.
audacity.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    echo 'set_target_properties(muse_extensions_qml PROPERTIES UNITY_BUILD OFF)' \
      >> muse/framework/extensions/qml/Muse/Extensions/CMakeLists.txt
  '';
})
