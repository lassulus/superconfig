{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # update-pkgs [attr...]   (no attrs: every package with an updateScript)
      #
      # Runs passthru.updateScript the way nixpkgs' maintainers/scripts/update.py
      # does (UPDATE_NIX_ATTR_PATH/PNAME/OLD_VERSION/NAME, cwd = flake root),
      # for this flake's packages. Packages missing from the host's package set
      # (linux-only ones on darwin) are taken from x86_64-linux; nix-update in
      # their command is swapped for the host's, the rest of the command stays.
      packages.update-pkgs =
        (pkgs.writeShellApplication {
          name = "update-pkgs";
          runtimeInputs = [
            pkgs.git
            pkgs.jq
            pkgs.nix-update
          ];
          text = ''
            root=$(git rev-parse --show-toplevel)
            cd "$root"
            host=$(nix eval --raw --impure --expr builtins.currentSystem)
            all=$(nix eval --json --impure --expr "import ${./scripts.nix} { flake = \"$root\"; host = \"$host\"; }")

            if [ "''${1:-}" = --list ]; then
              jq -r 'to_entries[] | "\(.key)\t\(.value.cmd | join(" "))"' <<<"$all"
              exit 0
            fi
            if [ $# -gt 0 ]; then
              attrs=("$@")
            else
              mapfile -t attrs < <(jq -r 'keys[]' <<<"$all")
            fi

            failed=()
            for attr in "''${attrs[@]}"; do
              entry=$(jq -c --arg a "$attr" '.[$a] // empty' <<<"$all")
              if [ -z "$entry" ]; then
                echo "update-pkgs: $attr has no updateScript" >&2
                failed+=("$attr")
                continue
              fi
              mapfile -t cmd < <(jq -r '.cmd[]' <<<"$entry")
              case "''${cmd[0]}" in
              */bin/nix-update) cmd[0]=nix-update ;;
              esac
              printf '\n\033[1m== %s\033[0m\n' "$attr" >&2
              if ! UPDATE_NIX_ATTR_PATH=$attr \
                UPDATE_NIX_PNAME=$(jq -r .pname <<<"$entry") \
                UPDATE_NIX_OLD_VERSION=$(jq -r .version <<<"$entry") \
                UPDATE_NIX_NAME=$(jq -r .name <<<"$entry") \
                "''${cmd[@]}"; then
                failed+=("$attr")
              fi
            done

            if [ ''${#failed[@]} -gt 0 ]; then
              echo "update-pkgs: failed: ''${failed[*]}" >&2
              exit 1
            fi
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
