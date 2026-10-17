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
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes."fuse-backend-rs-0.14.0" = "sha256-pSnYq8IhfpxtnTS7bnE8GHAVP+yZ+hItChTEmGUP7xM=";
    outputHashes."harmonia-file-core-3.3.0" = "sha256-aPNxxJLjRd+wVFyAcUnzrakC0BNj/N9rJWV2y8wpCAs=";
  };
  # Static, so that once it serves /nix/store it loads nothing from there.
  # (Not glibc.static in buildInputs: build scripts would link against it.)
  env.RUSTFLAGS = "-C target-feature=+crt-static -L native=${glibc.static}/lib";

  doInstallCheck = true;
  installCheckPhase = ''
    if $READELF -l $out/bin/lazy-store | grep -q INTERP; then
      echo "lazy-store is not static"; exit 1
    fi
    ($out/bin/lazy-store || true) 2>&1 | grep -q usage
  '';

  # closure and the lower layer against a file:// cache, without FUSE:
  # nix build .#lazy-store.tests.fetch
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
        mkdir -p src/a/sub cache/nar out closure
        echo hello > src/a/file
        printf '#!/bin/sh\n' > src/a/sub/run
        chmod +x src/a/sub/run
        ln -s file src/a/link
        echo single > src/b
        cp -a src/a src/c

        A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a
        B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b
        C=cccccccccccccccccccccccccccccccc-c
        D=dddddddddddddddddddddddddddddddd-d
        # store path hashes are nix32, which has no e
        E=ffffffffffffffffffffffffffffffff-f
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

        # a refers to b; d refers to e, which no cache has: d is left out
        narinfo() { # name url references
          printf 'StorePath: /nix/store/%s\nURL: %s\nCompression: zstd\nNarHash: sha256:%s\nNarSize: 8\nReferences: %s\nSig: test-1:%s\n' \
            "$1" "$2" "$(nix-hash --type sha256 --base32 src/b)" "$3" "$(printf %64s | base64 -w0)" \
            > "cache/''${1%%-*}.narinfo"
        }
        narinfo $A nar/a.nar.zst "$A $B"
        narinfo $B nar/b.nar.xz ""
        narinfo $D nar/d.nar.zst "$E"
        printf '/nix/store/%s\n' $A $D | LAZY_STORE_CACHES="file://$PWD/cache" lazy-store closure closure
        jq -e '.paths == 2 and .missing == ["'$E'"] and .incomplete == 1' closure/closure.json
        jq -e 'keys == ["'$A'", "'$B'"]' closure/paths.json
        if grep -q $D closure/db.dump; then
          echo "path with an incomplete closure was registered"; exit 1
        fi

        # registered as .github/lazy-store.sh does, with the signatures
        export NIX_CONFIG="experimental-features = nix-command"
        root="local?root=$PWD/root"
        nix-store --store "$root" --load-db < closure/db.dump
        printf '/nix/store/%s\n' $A $B |
          nix store copy-sigs --store "$root" -s "file://$PWD/closure/narinfo" --stdin
        nix path-info --store "$root" --sigs /nix/store/$A | grep -q "[[:space:]]test-1:$(printf %64s | base64 -w0)$"
        test "$(nix-store --store "$root" -q --references /nix/store/$A | wc -l)" = 2

        # b's listing is broken: b and a, which refers to it, are left out,
        # c is served
        echo broken > cache/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.ls
        printf 'StorePath: /nix/store/%s\nURL: nar/c.nar.zst\nCompression: zstd\nNarHash: sha256:%s\nNarSize: %s\nReferences: \n' \
          $C "$(nix-hash --type sha256 --base32 src/c)" "$(size src/c)" > cache/cccccccccccccccccccccccccccccccc.narinfo
        mkdir partial
        printf '/nix/store/%s\n' $A $C | LAZY_STORE_CACHES="file://$PWD/cache" lazy-store closure partial
        lazy-store fetch partial $C
        diff -r src/c partial/cache/$C
        jq -e '.failed == ["'$B'"] and .incomplete == 1' partial/no-listing.json
        jq -e 'keys == ["'$C'"]' partial/paths.json
        test "$(grep -c ^/nix/store/ partial/db.dump)" = 1
        grep -qx /nix/store/$C partial/db.dump
        if lazy-store fetch partial $A; then
          echo "path referring to one without a listing was served"; exit 1
        fi
        touch $out
      '';

  meta.mainProgram = "lazy-store";
  meta.platforms = lib.platforms.linux;
})
