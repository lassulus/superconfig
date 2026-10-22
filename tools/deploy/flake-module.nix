{ self, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      # deploy [--flake PATH] [--yes] <machine> [[user@]host]   (host defaults to <machine>.r)
      #
      # Generates vars, copies the flake source to /var/lib/deploy/incoming
      # on the target, builds it there in the systemd unit deploy-build
      # (progress via nom), shows the source diff against the running system
      # (/var/lib/deploy/src) and the closure diff, asks (--yes: does not
      # ask and prints the diffs without a pager), then uploads
      # secrets and switches in the unit deploy-switch, which records the
      # deployed git revision in /var/lib/superconfig-revision. Both units
      # survive the ssh connection dying; rerunning deploy attaches to a
      # running one.
      packages.deploy =
        (pkgs.writeShellApplication {
          name = "deploy";
          runtimeInputs = [
            self.packages.${system}.pass
            self.packages.${system}.clan-cli
            pkgs.gnutar
            pkgs.jq
            pkgs.less
            pkgs.nix-output-monitor
          ];
          text = ''
            usage() {
              echo "usage: deploy [--flake PATH] [--yes] <machine> [[user@]host]  (host defaults to <machine>.r)" >&2
              exit 1
            }

            flake=.
            yes=0
            while [ $# -gt 0 ]; do
              case $1 in
              --flake)
                [ $# -ge 2 ] || usage
                flake=$2
                shift 2
                ;;
              --yes | -y)
                yes=1
                shift
                ;;
              -*) usage ;;
              *) break ;;
              esac
            done
            [ $# -eq 1 ] || [ $# -eq 2 ] || usage
            machine=$1
            target=''${2:-$machine.r}
            [[ $target == *@* ]] || target=root@$target

            state=/var/lib/deploy
            nix="/run/current-system/sw/bin/nix --extra-experimental-features 'nix-command flakes'"

            tmp=$(mktemp -d)
            chmod 700 "$tmp"
            # One ssh connection for the whole run, so the key signs only once.
            ssh_opts=(-o ControlMaster=auto -o "ControlPath=$tmp/ssh" -o ControlPersist=yes)
            cleanup() {
              ssh "''${ssh_opts[@]}" -O exit "$target" 2>/dev/null || true
              rm -rf "$tmp"
            }
            trap cleanup EXIT

            remote() {
              # shellcheck disable=SC2029 # the command line is meant for the target
              ssh "''${ssh_opts[@]}" "$target" "$@"
            }
            step() {
              printf '\n\033[1m== %s\033[0m\n' "$*" >&2
            }
            page() {
              if [ -t 1 ] && [ "$yes" = 0 ]; then ''${PAGER:-less -RFX}; else cat; fi
            }

            # True while the unit's ExecStartPre or ExecStart is running.
            # Finished units stay around (RemainAfterExit) until the next start,
            # so their result can still be read after reconnecting.
            in_progress() {
              case $(remote systemctl show -p ActiveState -p SubState "$1") in
              *ActiveState=activating* | *SubState=running*) return 0 ;;
              esac
              return 1
            }

            # start <unit> <systemd-run args...>: the arguments are quoted, so
            # they reach systemd-run on the target unchanged. Units start with
            # an empty environment; go through the daemon like a login shell
            # (the store is read-only inside containers).
            start() {
              local unit=$1
              shift
              remote "systemctl stop $unit 2>/dev/null; systemctl reset-failed $unit 2>/dev/null;" \
                "systemd-run --quiet --unit=$unit -p RemainAfterExit=yes" \
                "-p StandardOutput=truncate:$state/$unit.log" \
                "--setenv=NIX_REMOTE=daemon --setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin" \
                "$(printf ' %q' "$@")"
            }

            # follow <unit>: stream its log until it finishes, fail if it did.
            # tail can lag far behind the log when the reader (nom) is slow, so
            # it must not be killed on a timer: --pid makes it read the log to
            # the end once the waiter (unit finished) is gone, then exit, so
            # no line is cut off. systemctl fails for a moment while a switch
            # reexecutes systemd ("Failed to connect to system scope bus");
            # that is retried, not taken for the unit having finished.
            follow() {
              ssh "''${ssh_opts[@]}" "$target" bash -s -- "$1" "$state" <<'EOF'
            unit=$1 log=$2/$1.log
            query() {
              until systemctl show "$@" "$unit" 2>/dev/null; do sleep 1; done
            }
            while case $(query -p ActiveState -p SubState) in
              *ActiveState=activating* | *SubState=running*) true ;;
              *) false ;;
              esac; do
              sleep 1
            done &
            tail -n +1 -F --pid=$! "$log" 2>/dev/null
            [ "$(query -p Result --value)" = success ] && exit 0
            echo "deploy: $unit failed (exit status $(query -p ExecMainStatus --value)), log: $log" >&2
            exit 1
            EOF
            }

            # source_diff: per-file +/- summary, then the full diff, of the
            # running system's source against the incoming one.
            source_diff() {
              ssh "''${ssh_opts[@]}" "$target" bash -s -- "$state" <<'EOF'
            old=$1/src new=$1/incoming
            if [ ! -d "$old" ]; then
              echo "no source recorded for the running system"
              exit 0
            fi
            # diff exits 1 when the trees differ, 2 on trouble.
            d() { diff -ruN "$@" "$old" "$new" || [ $? -eq 1 ]; }
            d | awk -v pre="$new/" '
              /^diff -ruN / {
                f = substr($0, index($0, " " pre) + 1 + length(pre))
                files[++n] = f; hdr = 2; next
              }
              hdr > 0 { hdr--; next }
              /^\+/ { add[f]++ }
              /^-/ { del[f]++ }
              END {
                if (n == 0) { print "no source changes"; exit }
                for (i = 1; i <= n; i++) {
                  f = files[i]
                  printf " %-60s \033[32m+%d\033[0m \033[31m-%d\033[0m\n", f, add[f], del[f]
                }
                printf "%d files changed\n\n", n
              }'
            d --color=always
            EOF
            }

            step "connecting to $target"
            remote true || { echo "deploy: cannot reach $target" >&2; exit 1; }
            # shellcheck disable=SC2016 # expanded on the target
            remote 'test -e /etc/NIXOS && command -v systemd-run >/dev/null' ||
              { echo "deploy: $target is not a NixOS system with systemd" >&2; exit 1; }
            if in_progress deploy-switch; then
              step "a switch is still running on $target, attaching"
              follow deploy-switch
              exit
            fi

            # Decrypt the bulk key once (one Secure Enclave unlock); every
            # later pass call from clan then uses it without prompting.
            PASS_BULK_KEY_FILE="" pass show bulk-operations/age-key >"$tmp/bulk-key"
            if [ ! -s "$tmp/bulk-key" ]; then
              echo "deploy: could not extract the bulk key" >&2
              exit 1
            fi
            export PASS_BULK_KEY_FILE="$tmp/bulk-key"

            if in_progress deploy-build; then
              step "a build is still running on $target, attaching"
            else
              step "generating vars for $machine"
              pass git pull --rebase
              clan vars generate --flake "$flake" "$machine"
              pass git push

              step "copying source to $target:$state/incoming"
              # The flake source exactly as nix sees it: tracked files only.
              meta=$(nix flake metadata --json "$flake")
              src=$(jq -r .path <<<"$meta")
              # Its git revision (-dirty with uncommitted changes), written to
              # /var/lib/superconfig-revision once the switch succeeded.
              revision=$(jq -r '.revision // .dirtyRevision // "unknown"' <<<"$meta")
              tar -C "$src" --owner=0 --group=0 --numeric-owner -czf - . |
                remote "rm -rf $state/incoming.new && mkdir -p $state/incoming.new &&" \
                  "tar -C $state/incoming.new -xzf - &&" \
                  "rm -rf $state/incoming && mv $state/incoming.new $state/incoming &&" \
                  "echo $revision >$state/incoming.revision"

              step "source changes"
              source_diff | page

              step "building $machine on $target"
              # nvd comes from the machine's own nixpkgs, so it is built for
              # the target and usually substituted; out-links are result
              # (system) and result-1 (nvd), in installable order.
              start deploy-build \
                /run/current-system/sw/bin/nix --extra-experimental-features "nix-command flakes" \
                --log-format internal-json -v build --out-link "$state/result" \
                "$state/incoming#nixosConfigurations.$machine.config.system.build.toplevel" \
                "$state/incoming#nixosConfigurations.$machine.pkgs.nvd"
            fi
            follow deploy-build | nom --json
            system=$(remote readlink -f "$state/result")

            step "closure changes"
            if [ "$(remote readlink -f /run/current-system)" = "$system" ]; then
              echo "$system is already running"
            else
              remote "$state/result-1/bin/nvd diff /run/current-system $system"
            fi

            if [ "$yes" = 0 ]; then
              read -r -p "switch $target to $system? [y/N] " answer </dev/tty
              if [[ $answer != [yY]* ]]; then
                echo "aborted, $target is unchanged" >&2
                exit 1
              fi
            fi

            step "uploading secrets"
            secret_location=$(remote "$nix eval --raw $state/incoming#nixosConfigurations.$machine.config.clan.core.vars.password-store.secretLocation")
            clan vars upload --flake "$flake" --directory "$tmp/vars" "$machine"
            if [ -s "$tmp/vars/.pass_info" ] &&
              [ "$(remote cat "$secret_location/.pass_info" 2>/dev/null)" = "$(cat "$tmp/vars/.pass_info")" ]; then
              echo "secrets in $secret_location unchanged"
            else
              # Same layout and permissions as `clan vars upload`; swapped in
              # with a rename so the directory is never empty.
              find "$tmp/vars" -type d -exec chmod 700 {} +
              find "$tmp/vars" -type f -exec chmod 400 {} +
              # shellcheck disable=SC2016 # expanded on the target
              tar -C "$tmp/vars" --owner=0 --group=0 --numeric-owner -czf - . |
                remote "d=$secret_location;" \
                  'rm -rf "$d.new" "$d.old" && install -d -m 700 "$d.new" && tar -C "$d.new" -xzf - &&' \
                  '{ [ ! -e "$d" ] || mv "$d" "$d.old"; } && mv "$d.new" "$d" && rm -rf "$d.old"'
            fi

            step "switching $target"
            start deploy-switch \
              -p "ExecStartPre=/run/current-system/sw/bin/nix-env -p /nix/var/nix/profiles/system --set $system" \
              -p "ExecStartPre=/bin/sh -c 'rm -rf $state/src && cp -a $state/incoming $state/src'" \
              -p "ExecStartPost=/bin/sh -c '(cat $state/incoming.revision || echo unknown) >/var/lib/superconfig-revision.tmp && mv /var/lib/superconfig-revision.tmp /var/lib/superconfig-revision'" \
              "$system/bin/switch-to-configuration" switch
            follow deploy-switch
          '';
        }).overrideAttrs
          { passthru.usage = builtins.readFile ./usage.kdl; };
    };
}
