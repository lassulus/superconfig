{
  lib,
  writeShellApplication,
  nix,
  deno,
  coreutils,
  findutils,
  path,
  # attribute names in python3Packages added to its Python environment,
  # e.g. yt-dlp plugins like "bgutil-ytdlp-pot-provider"
  plugins ? [ ],
}:
# yt-dlp from its master branch: YouTube breaks released versions often, and
# fixes land on master days before a release reaches nixpkgs. Built at runtime
# against this nixpkgs; the build is reused for an hour, and when building
# fails the last build keeps working.
writeShellApplication {
  name = "yt-dlp";
  runtimeInputs = [
    nix
    deno
    coreutils
    findutils
  ];
  text = ''
    cache=''${XDG_CACHE_HOME:-$HOME/.cache}/yt-dlp-master
    mkdir -p "$cache"
    if [ -z "$(find "$cache/result" -maxdepth 0 -mmin -60 2>/dev/null)" ]; then
      if ! nix --extra-experimental-features 'nix-command flakes' build --quiet \
        --out-link "$cache/result" --impure --expr '
          let
            pkgs = import ${path} { };
            # an override for the whole set, so plugins depend on it too
            python = pkgs.python3.override {
              packageOverrides = _: super: {
                yt-dlp = super.yt-dlp.overridePythonAttrs (_: {
                  version = "0.99";
                  src = builtins.fetchTree "github:yt-dlp/yt-dlp";
                  patches = [ ];
                  postPatch = "python devscripts/update-version.py 0.99";
                });
              };
            };
          in
          python.withPackages (ps: [
            ps.yt-dlp
            ${lib.concatMapStringsSep " " (p: "ps.${lib.strings.escapeNixIdentifier p}") plugins}
          ])
        ' >&2; then
        if [ ! -e "$cache/result" ]; then
          echo "yt-dlp: building master failed" >&2
          exit 1
        fi
        echo "yt-dlp: building master failed, using the last build" >&2
      fi
      # the next try comes in an hour, also after a failure
      touch -h "$cache/result"
    fi
    exec "$cache/result/bin/yt-dlp" "$@"
  '';
}
