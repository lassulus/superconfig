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
            # Only update scripts written for this flake: nix-update with --flake,
            # or a script inside this flake. Packages wrapping nixpkgs or
            # flake-input packages otherwise inherit an updateScript meant for
            # that checkout; those follow flake.lock instead.
            src=$(nix flake metadata --json . | jq -r .path)

            # attr -> {cmd, pname, version, name}. Per package tryEval: one
            # package refusing to evaluate on this system must not hide the rest.
            scripts() {
              nix eval --json ".#packages.$1" --apply "
                ps: builtins.mapAttrs (n: p:
                  let
                    r = builtins.tryEval (
                      let
                        u = p.passthru.updateScript or null;
                        isOurs = s: s == \"--flake\"
                          || builtins.substring 0 (builtins.stringLength \"$src/\") s == \"$src/\";
                        c =
                          if builtins.isList u then u
                          else if builtins.isAttrs u && u ? command then
                            (if builtins.isList u.command then u.command else [ u.command ])
                          else [ u ];
                        v = {
                          cmd = map toString c;
                          pname = p.pname or n;
                          version = p.version or \"\";
                          name = p.name or n;
                        };
                      in
                      if u == null || !(builtins.any isOurs v.cmd) then null else builtins.deepSeq v v
                    );
                  in
                  if r.success then r.value else null) ps"
            }
            host_scripts=$(scripts "$host")
            linux_scripts='{}'
            if [ "$host" != x86_64-linux ]; then
              linux_scripts=$(scripts x86_64-linux)
            fi
            # host entries win over linux ones
            all=$(jq -s '.[1] + .[0] | with_entries(select(.value != null))' \
              <<<"$host_scripts $linux_scripts")

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
