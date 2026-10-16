#!/usr/bin/env bash
# Run by .github/workflows/exp-lazy-fuse.yml, which only checks out and
# installs nix: everything else lives here so that changing the experiment
# doesn't touch .github/workflows/.
#
# Rebuilds a machine's system-units, etc, system-path and toplevel on a fresh
# runner with a lazy /nix/store (see measure-lazy-store.yml on
# ci-lazy-measure for why).
#
# /nix/store becomes an overlayfs: upper = the runner's real store, lower = a
# FUSE mount (lazy-store.py) of everything the builds need from the caches.
# nix uses it as a local-overlay store whose lower store is a plain `local`
# store with a database loaded from narinfos only, so nix sees all inputs as
# valid without downloading them. The FUSE serves stat/readdir/readlink from
# the caches' .ls listings and fetches (and checks) a path's NAR on the first
# open() of a file in it.
#
# Everything worth looking at ends up in $RUNNER_TEMP/lazy-out, which the
# workflow uploads as an artifact even if this fails.
set -euo pipefail

MACHINE=${MACHINE:-neoprism}
here=$(cd "$(dirname "$0")" && pwd)
L=$RUNNER_TEMP/lazy     # paths.json, db.dump, unpacked NARs (root-owned)
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
  # build logs of the local-overlay store (state dir defaults to /nix/var/nix)
  sudo tar -C /nix/var/log/nix -cf "$O/nix-log.tar" . 2>/dev/null
  cp /etc/nix/nix.conf "$O/nix.conf"
  sudo chown -R "$(id -u):$(id -g)" "$O"
  if [ "$rc" != 0 ] && [ -s "$O/fuse.log" ]; then
    echo "::group::fuse.log (tail)"
    tail -n 100 "$O/fuse.log"
    echo "::endgroup::"
  fi
  exit "$rc"
}
trap collect EXIT

# from apt: nothing in the nix store besides nix itself before measuring.
# fusepy uses libfuse2 (libfuse2t64); as root it mounts without fusermount.
sudo apt-get install -y -q python3-fusepy zstd
sudo modprobe fuse || true
ls -l /dev/fuse
grep -qx user_allow_other /etc/fuse.conf 2>/dev/null ||
  echo user_allow_other | sudo tee -a /etc/fuse.conf >/dev/null
# The run that installed python3-fusepy still failed `import fuse` with
# /usr/bin/python3, so don't rely on where the package put it: put the dir of
# its fuse.py on PYTHONPATH, and failing that take fusepy (one pure-python
# file over ctypes) from PyPI.
/usr/bin/python3 -c 'import sys; print(sys.version); print(sys.path)'
dpkg -L python3-fusepy | grep -E '\.py$' || true
py=$L/py
mkdir -p "$py"
fusepy=$(dpkg -L python3-fusepy | grep -E '/fuse\.py$' | head -n 1 || true)
[ -n "$fusepy" ] && ln -sf "$fusepy" "$py/fuse.py"
fuse_ok() {
  PYTHONPATH=$py /usr/bin/python3 -c 'import fuse; print("fusepy", fuse.__file__, getattr(fuse, "_libfuse_path", "?"))'
}
if ! fuse_ok; then
  echo "fusepy from apt not importable, installing it from PyPI into $py"
  rm -f "$py/fuse.py"
  /usr/bin/python3 -m pip install -q --no-deps --break-system-packages --target "$py" fusepy==3.0.1
  fuse_ok
fi

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

python3 "$here/lazy-store.py" closure "$L" "${targets[@]}"
phase "narinfo closure" "$(jq -r '"\(.paths) paths"' "$L/closure.json")"

# The database is loaded through a store whose real dir is a scratch dir:
# opening a writable `local` store creates <real>/.links, and with
# real=/lazy/store that left the FUSE mount point non-empty, which libfuse2
# refuses (the first run died right here). Only the db in state= matters.
lower="local?real=/lazy/store&state=/lazy/state"
sudo mkdir -p /lazy/store /lazy/state /lazy/load-real /lazy/nix /nix/.lazy-work
# shellcheck disable=SC2024 # $L is ours, only nix-store needs root
sudo "$nixbin/nix-store" --option store "local?real=/lazy/load-real&state=/lazy/state" \
  --load-db <"$L/db.dump"
sudo ls -la /lazy/store

# shellcheck disable=SC2024 # the log is ours, only the mount needs root
sudo env PYTHONPATH="$py" /usr/bin/python3 -u "$here/lazy-store.py" mount "$L" /lazy/store >"$O/fuse.log" 2>&1 &
fuse_pid=$!
for _ in $(seq 300); do
  mountpoint -q /lazy/store && break
  fuse_alive || fuse_died "exited before /lazy/store was mounted"
  sleep 0.1
done
mountpoint -q /lazy/store || fuse_died "/lazy/store not mounted after 30 s"
# ls -f: no stat(), which would fetch every path's .ls listing
# shellcheck disable=SC2012
echo "/lazy/store: $(ls -f /lazy/store | wc -l) entries"
fuse_alive || fuse_died "exited right after mounting"

# private, so the overlay mounted on /nix/store doesn't show up here
sudo mount --bind /nix /lazy/nix
sudo mount --make-private /lazy/nix
sudo mount -t overlay overlay \
  -o lowerdir=/lazy/store,upperdir=/lazy/nix/store,workdir=/lazy/nix/.lazy-work /nix/store
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
store="local-overlay://?upper-layer=/lazy/nix/store&check-mount=false&lower-store=$(enc "$lower&read-only=true")"
lnix() { sudo "$nixbin/nix-store" --option store "$store" "$@"; }
phase "mount lazy store"

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
