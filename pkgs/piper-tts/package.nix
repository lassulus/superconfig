{ piper-tts }:
# piper-tts without Japanese support, which pulls in pyopenjtalk-plus: its
# tests fail with Cython 3.3 (fixed by NixOS/nixpkgs#576063). We only use
# English voices (configs/services/radio/tts.nix, machines/coaxmetal/hermes.nix).
# Drop this package once our nixpkgs pin includes that fix.
piper-tts.override { withJapanese = false; }
