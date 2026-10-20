{ noctalia-qs }:
# noctalia-qs 0.0.12 fails against Qt 6.12 ("Meta Types must be fully
# defined" in the hyprland ipc mocs). qt-6.12.patch backports quickshell
# 5d5d49873f ("all: use MOC includes instead of opaque pointer
# definitions") to the fork, whose i3 getters are non-const. Drop this
# package once nixpkgs' noctalia-qs builds again.
noctalia-qs.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./qt-6.12.patch ];
})
