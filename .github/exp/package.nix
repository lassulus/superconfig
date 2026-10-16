{
  lib,
  rustPlatform,
  glibc,
  runCommand,
  nix,
  zstd,
  xz,
  jq,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "lazy-store";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./lazy-store;
    fileset = ./lazy-store;
  };
  cargoLock = {
    lockFile = ./lazy-store/Cargo.lock;
    outputHashes."fuse-backend-rs-0.14.0" = "sha256-pSnYq8IhfpxtnTS7bnE8GHAVP+yZ+hItChTEmGUP7xM=";
  };
  # Static, so that lazy-fuse.sh can build it in a separate store (keeping
  # the real one free of the toolchain's closure, which overlaps with the
  # paths the lazy layer is measured on) and run it from there.
  # (Not glibc.static in buildInputs: build scripts would link against it.)
  env.RUSTFLAGS = "-C target-feature=+crt-static -L native=${glibc.static}/lib";

  doInstallCheck = true;
  installCheckPhase = ''
    if $READELF -l $out/bin/lazy-store | grep -q INTERP; then
      echo "lazy-store is not static"; exit 1
    fi
    ($out/bin/lazy-store || true) 2>&1 | grep -q usage
  '';

  # The lower layer against a file:// cache, without FUSE:
  # nix build -f .github/exp passthru.tests.fetch
  passthru.tests.fetch =
    runCommand "lazy-store-fetch-test"
      {
        nativeBuildInputs = [
          finalAttrs.finalPackage
          nix
          zstd
          xz
          jq
        ];
      }
      ''
        export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/state NIX_LOG_DIR=$TMPDIR/log
        mkdir -p src/a/sub cache/nar out
        echo hello > src/a/file
        printf '#!/bin/sh\n' > src/a/sub/run
        chmod +x src/a/sub/run
        ln -s file src/a/link
        echo single > src/b
        cp -a src/a src/c

        A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a
        B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b
        C=cccccccccccccccccccccccccccccccc-c
        ls='{"version":1,"root":{"type":"directory","entries":{
          "file":{"type":"regular","size":6},
          "link":{"type":"symlink","target":"file"},
          "sub":{"type":"directory","entries":{"run":{"type":"regular","size":10,"executable":true}}}}}}'
        # zstd .ls served without Content-Encoding (sniffed); b has none
        echo "$ls" | zstd -q > cache/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ls
        echo "$ls" | zstd -q > cache/cccccccccccccccccccccccccccccccc.ls

        nix-store --dump src/a | zstd -q > cache/nar/a.nar.zst
        nix-store --dump src/b | xz > cache/nar/b.nar.xz
        nix-store --dump src/c | zstd -q > cache/nar/c.nar.zst
        info() { # name file compression hash size
          jq -n --arg c "file://$PWD/cache" --arg u "$2" --arg z "$3" --arg h "$4" --argjson s "$5" \
            '{($ARGS.positional[0]): {cache: $c, url: $u, compression: $z, narHash: $h, narSize: $s, fileSize: 0}}' \
            --args "$1"
        }
        size() { nix-store --dump "$1" | wc -c; }
        {
          info $A nar/a.nar.zst zstd "sha256:$(nix-hash --type sha256 --base32 src/a)" "$(size src/a)"
          info $B nar/b.nar.xz xz "sha256:$(nix-hash --type sha256 src/b)" "$(size src/b)"
          # wrong hash: must not be unpacked
          info $C nar/c.nar.zst zstd "sha256:$(nix-hash --type sha256 --base32 src/b)" "$(size src/c)"
        } | jq -s add > out/paths.json

        lazy-store fetch out $A $B
        diff -r src/a out/cache/$A
        diff src/b out/cache/$B
        test "$(stat -c %a out/cache/$A/sub/run)" = 555
        test "$(stat -c %a out/cache/$A/file)" = 444
        test "$(readlink out/cache/$A/link)" = file
        jq -e '.ls_count == 2 and .nar_count == 2' out/stats.json
        if lazy-store fetch out $C; then
          echo "NAR with a wrong hash was accepted"; exit 1
        fi
        test ! -e out/cache/$C
        touch $out
      '';

  meta.mainProgram = "lazy-store";
})
