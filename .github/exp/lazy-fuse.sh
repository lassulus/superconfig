#!/usr/bin/env bash
# Run by .github/workflows/exp-lazy-fuse.yml, which only checks out and
# installs nix: everything else lives here so that changing the experiment
# doesn't touch .github/workflows/.
#
# Rebuilds a machine's system-units, etc, system-path and toplevel on a fresh
# runner with a lazy /nix/store (see measure-lazy-store.yml on
# ci-lazy-measure for why).
#
# /nix/store becomes one FUSE file system (lazy-store/, Rust on
# fuse-backend-rs): the runner's real store dir, through which all writes go,
# merged with every store path the builds need from the caches. Those are
# served from their .ls listings (all fetched up front, metadata is answered
# from memory) and a path's NAR is fetched, checked and unpacked on the first
# open() of a file in it; reads then go through kernel FUSE passthrough. nix
# stays a plain local store: the input paths are registered in its database
# from their narinfos (nix-store --load-db), so it sees them as valid without
# downloading them.
#
# Everything worth looking at ends up in $RUNNER_TEMP/lazy-out, which the
# workflow uploads as an artifact even if this fails.
set -euo pipefail

MACHINE=${MACHINE:-neoprism}
here=$(cd "$(dirname "$0")" && pwd)
L=$RUNNER_TEMP/lazy     # paths.json, db.dump, lazy-store, unpacked NARs (root-owned)
O=$RUNNER_TEMP/lazy-out # uploaded
mkdir -p "$L" "$O"
fuse_pid=

fuse_alive() {
  local s
  s=$(ps -o stat= -p "$fuse_pid" 2>/dev/null) && [[ $s != Z* ]]
}

fuse_died() {
  echo "::error::lazy FUSE process ($fuse_pid) is gone: $1"
  echo "::group::fuse.log"
  cat "$O/fuse.log" || true
  echo "::endgroup::"
  exit 1
}

collect() {
  local rc=$?
  set +e
  if [ -n "$fuse_pid" ] && ! fuse_alive; then
    echo "::error::lazy FUSE process ($fuse_pid) died during the run"
    rc=1
  fi
  sudo dmesg | tail -n 300 >"$O/dmesg.txt"
  cat /proc/self/mountinfo >"$O/mountinfo.txt"
  findmnt -l >"$O/findmnt.txt"
  ps -ef >"$O/ps.txt"
  cp "$L"/*.json "$O"/ 2>/dev/null
  # build logs (state dir /nix/var/nix, not in the store)
  sudo tar -C /nix/var/log/nix -cf "$O/nix-log.tar" . 2>/dev/null
  # the installer put the job's GitHub token into access-tokens
  sed 's/^\(access-tokens *=\).*/\1 <redacted>/' /etc/nix/nix.conf >"$O/nix.conf"
  sudo chown -R "$(id -u):$(id -g)" "$O"
  if [ "$rc" != 0 ] && [ -s "$O/fuse.log" ]; then
    echo "::group::fuse.log (tail)"
    tail -n 100 "$O/fuse.log"
    echo "::endgroup::"
  fi
  exit "$rc"
}
trap collect EXIT

uname -r
sudo modprobe fuse || true
ls -l /dev/fuse

nixbin=$(dirname "$(readlink -f "$(command -v nix-store)")")
rx() { awk -F'[: ]+' 'NR > 2 && $2 != "lo" { s += $3 } END { print s }' /proc/net/dev; }
rows=()
t0=$(date +%s.%N) r0=$(rx)
phase() {
  local t1 r1
  t1=$(date +%s.%N) r1=$(rx)
  rows+=("$(awk -v n="$1" -v t="$t1" -v t0="$t0" -v r="$r1" -v r0="$r0" -v x="${2:-}" \
    'BEGIN { printf "| %s | %.1f s | %.1f MiB | %s |", n, t - t0, (r - r0) / 2^20, x }')")
  t0=$t1 r0=$r1
}

# The lazy store is built in a separate store (chroot store under /lazy/build)
# so that the real one holds nothing besides nix (and eval's .drv files)
# before measuring: its toolchain's closure (glibc, gcc-lib, ...) overlaps
# with the paths the builds below need. The binary is static and runs from
# there. Only the .drv closure is instantiated in the real store.
drv=$(nix-instantiate "$here")
bs=/lazy/build
sudo mkdir -p "$bs"
# shellcheck disable=SC2046 # one path per word
nix-store --export $(nix-store -qR "$drv") |
  sudo "$nixbin/nix-store" --store "local?root=$bs" --import >/dev/null
out=$(sudo "$nixbin/nix-store" --store "local?root=$bs" --realise "$drv")
lazy=$L/lazy-store
sudo install -m 755 "$bs$out/bin/lazy-store" "$lazy"
phase "build lazy-store" "not part of the comparison"

top=$(nix eval --raw ".#nixosConfigurations.$MACHINE.config.system.build.toplevel.drvPath")
pick() {
  local r
  r=$(nix-store -q --references "$1" | grep -E -- "-$2\.drv\$")
  [ -n "$r" ] && [ "$(wc -l <<<"$r")" = 1 ] || {
    echo "no unique $2 in $1: $r" >&2
    return 1
  }
  echo "$r"
}
etc=$(pick "$top" etc)
units=$(pick "$etc" system-units)
path=$(pick "$top" system-path)
targets=("$units" "$etc" "$path" "$top")
phase eval

"$lazy" closure "$L" "${targets[@]}"
phase "narinfo closure" "$(jq -r '"\(.paths) paths"' "$L/closure.json")"

# The upper layer is the real store dir, reached through a private bind
# mount of /nix, so that the mount on /nix/store doesn't show up there.
sudo mkdir -p /lazy/nix
sudo mount --bind /nix /lazy/nix
sudo mount --make-private /lazy/nix
# shellcheck disable=SC2024 # the log is ours, only the mount needs root
sudo "$lazy" mount "$L" /lazy/nix/store /nix/store >"$O/fuse.log" 2>&1 &
fuse_pid=$!
# before mounting it fetches all .ls listings
for _ in $(seq 1200); do
  mountpoint -q /nix/store && break
  fuse_alive || fuse_died "exited before /nix/store was mounted"
  sleep 0.5
done
mountpoint -q /nix/store || fuse_died "/nix/store not mounted after 600 s"
# ls -f: no stat() of every entry
# shellcheck disable=SC2012
echo "/nix/store: $(ls -f /nix/store | wc -l) entries"
"$nixbin/nix-store" --version
fuse_alive || fuse_died "exited right after mounting"

# shellcheck disable=SC2024 # $L is ours, only nix-store needs root
sudo "$nixbin/nix-store" --load-db <"$L/db.dump"
lnix() { sudo "$nixbin/nix-store" "$@"; }
phase "mount lazy store" "$(sudo jq -r '"\(.ls_count // 0) listings"' "$L/stats.json")"

checks=()
for t in "${targets[@]}"; do
  name=${t#/nix/store/*-}
  name=${name%.drv}
  # --check needs the existing output; build it fresh if no cache has it
  mapfile -t outs < <(nix-store -q --outputs "$t")
  mode=(--check)
  lnix --check-validity "${outs[@]}" 2>/dev/null || mode=()
  rc=0
  lnix --realise "${mode[@]}" "$t" >/dev/null 2>"$O/build-$name.log" || rc=$?
  subst=$(grep -c "^copying path" "$O/build-$name.log" || true)
  phase "$name ${mode[0]:-build}" "exit $rc, $subst paths substituted eagerly"
  checks+=("$rc")
  if [ "$rc" != 0 ]; then
    echo "::group::build-$name.log (tail)"
    tail -n 50 "$O/build-$name.log"
    echo "::endgroup::"
  fi
  fuse_alive || fuse_died "exited while building $name"
done

sudo cp "$L"/stats.json "$O"/ 2>/dev/null || true
sudo chown -R "$(id -u):$(id -g)" "$O"
{
  echo "# lazy fuse store: $MACHINE"
  echo
  # shellcheck disable=SC2016 # markdown backticks
  printf -- '- `%s`\n' "${targets[@]}"
  echo
  echo "| phase | wall | network rx | |"
  echo "|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
  echo
  jq -r '"lower store: \(.paths) paths from \(.roots) roots, \(.by_cache | to_entries | map("\(.value) from \(.key)") | join(", ")); missing from the caches: \(.missing | length)",
    "an eager substitution would download \(.file_size / 1048576 | floor) MiB (\(.nar_size / 1048576 | floor) MiB unpacked)",
    "narinfo: \(.narinfo_count) requests, \(.narinfo_bytes / 1024 | floor) KiB"' "$L/closure.json"
  echo
  grep -m1 '^init: ' "$O/fuse.log" || true
  echo
  jq -r '"lazy layer: \(.ls_count // 0) .ls listings (\((.ls_bytes // 0) / 1024 | floor) KiB), \(.nar_count // 0) NARs (\((.nar_bytes // 0) / 1048576 * 10 | floor / 10) MiB, \((.nar_unpacked_bytes // 0) / 1048576 * 10 | floor / 10) MiB unpacked)",
    "",
    "| NAR fetched on open() | download | unpacked |", "|---|---|---|",
    (.nars | sort_by(-.[1]) | .[] | "| \(.[0]) | \(.[1] / 1024 | floor) KiB | \(.[2] / 1024 | floor) KiB |")' "$O/stats.json"
  if [ -s "$O/fuse.log" ]; then
    echo
    echo '```'
    grep -v '^fetched ' "$O/fuse.log" | tail -n 50
    echo '```'
  fi
} | tee -a "$GITHUB_STEP_SUMMARY" "$O/summary.md"
for rc in "${checks[@]}"; do [ "$rc" = 0 ]; done
