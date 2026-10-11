# shellcheck shell=bash
# (writeShellApplication adds the shebang and `set -euo pipefail`.)

# On-demand nix-grpc-store farm across GitHub Actions runners.
#
# Runners can't reach each other, so every hop goes through an iroh tunnel
# (dumbpipe) that ends on 127.0.0.1 on both sides:
#
#   farm job                                   worker job i
#   client ─► envoy :50051                     daemon :5100 (builder)
#               ├─► daemon :50052 ◄─ iroh ─ :5101 scheduler session
#               └─► :511i ─────────── iroh ─► :5100 builds
#   daemon :50052 (scheduler + builder)
#
# Every daemon and envoy present the same TLS identity (FARM_KEY with
# farm.crt, SAN 127.0.0.1) and accept only it, as `trusted`. The iroh
# endpoint keys are derived from FARM_KEY, so it is the only secret. Outputs
# go to niks3 with the job's GitHub OIDC token.

state=/tmp/ci-farm
niks3_url=https://niks3.lassul.us

mkdir -p "$state"
chmod 700 "$state"
printf '%s\n' "${FARM_KEY:?FARM_KEY must hold the farm private key}" >"$state/farm.key"
chmod 600 "$state/farm.key"
unset FARM_KEY
# Where envoy's config (flake-module.nix) expects it, next to the key.
install -m 644 "$FARM_CRT" "$state/farm.crt"
FARM_CRT=$state/farm.crt

seed=$(sha256sum <"$state/farm.key" | cut -d' ' -f1)
derive() { printf '%s:%s' "$seed" "$1" | sha256sum | cut -d' ' -f1; }
ticket() { IROH_SECRET=$(derive "iroh-$1") dumbpipe generate-ticket; }

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

# The GitHub OIDC token of the job, refreshed in the background (niks3 re-reads
# the file, the daemon notices the new inode). Outside Actions, point
# NIKS3_TOKEN_FILE at a niks3 API token instead.
niks3_token() {
  curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?needs id-token: write, or NIKS3_TOKEN_FILE}" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$niks3_url" |
    jq -er .value >"$state/niks3-token.new"
  mv "$state/niks3-token.new" "$state/niks3-token"
}
if [ -n "${NIKS3_TOKEN_FILE:-}" ]; then
  ln -sf "$NIKS3_TOKEN_FILE" "$state/niks3-token"
else
  niks3_token
  (while sleep 120; do niks3_token || echo "ci-farm: refreshing the niks3 token failed" >&2; done) &
fi

daemon=(
  nix-grpc-daemon
  --proxy-socket /nix/var/nix/daemon-socket/socket
  --tls-cert "$FARM_CRT"
  --tls-key "$state/farm.key"
  --client-ca "$FARM_CRT"
  --allow farm=trusted
  --niks3 "$niks3_url"
  --niks3-token-file "$state/niks3-token"
  # cache.nixos.org keeps serving what it signed; only push our own paths
  --niks3-push "niks3 push --ignore-upstream-key cache.nixos.org-1"
  --min-free 2G
)

wait_http() {
  for _ in $(seq 60); do
    curl -fs -o /dev/null "$1" && return
    sleep 1
  done
  echo "ci-farm: $1 did not come up" >&2
  exit 1
}

# Workers appear in envoy's clusters once their session with the scheduler is
# up. Their tunnels resolve the farm through iroh discovery, which takes a
# while after the farm comes online, so give them time before handing out
# work. Builds start anyway after the timeout, with whoever has joined.
wait_workers() {
  local want=$1 have=0
  for _ in $(seq 60); do
    have=$(curl -fs http://127.0.0.1:9901/clusters |
      grep -cE '::127\.0\.0\.1:511[0-9]+::health_flags::healthy$' || true)
    [ "$have" -ge "$want" ] && break
    sleep 5
  done
  echo "ci-farm: $have of $want workers joined"
}

# ci-farm farm ARG...: ARG is a NixOS machine of this flake (its toplevel is
# built) or a /nix/store/….drv.
farm() {
  local workers=${FARM_WORKERS:?FARM_WORKERS: number of worker jobs}
  IROH_SECRET=$(derive iroh-farm) dumbpipe listen-tcp --host 127.0.0.1:50052 &
  for i in $(seq "$workers"); do
    IROH_SECRET=$(derive "iroh-farm-dial-$i") \
      dumbpipe connect-tcp --addr "127.0.0.1:$((5110 + i))" "$(ticket "worker-$i")" &
  done
  "${daemon[@]}" --role builder,scheduler --listen 127.0.0.1:50052 \
    --advertise 127.0.0.1:50052 --worker-name farm &
  envoy -c "$ENVOY_CONFIG" --log-level warn &
  wait_http http://127.0.0.1:9901/ready
  wait_workers "$workers"

  local store="grpc://127.0.0.1:50051?insecure=1&system=x86_64-linux"
  declare -A builds
  for arg in "$@"; do
    if [[ $arg == /nix/store/*.drv ]]; then
      drv=$arg
    else
      # One eval process per machine: all hosts at once don't fit in 16 GB.
      drv=$(nix eval --raw ".#nixosConfigurations.$arg.config.system.build.toplevel.drvPath")
    fi
    echo "ci-farm: $arg: $drv"
    "$NIX_WITH_PLUGIN" build --no-link --print-out-paths --store "$store" --eval-store auto "$drv^*" 2>&1 |
      sed -u "s|^|[$arg] |" &
    builds[$arg]=$!
  done

  local failed=()
  for arg in "${!builds[@]}"; do
    wait "${builds[$arg]}" || failed+=("$arg")
  done
  if [ ${#failed[@]} -gt 0 ]; then
    echo "ci-farm: failed: ${failed[*]}" >&2
    exit 1
  fi
}

# Outside Actions there is no farm job to watch: run until killed.
farm_done() {
  [ -n "${GITHUB_RUN_ID:-}" ] &&
    [ "$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs" \
      --jq '.jobs[] | select(.name == "farm") | .status')" = completed ]
}

# A dumbpipe dialer started before the farm is discoverable never reaches it,
# not even once the farm is online. Probe with short-lived dialers until the
# farm daemon answers a gRPC health check, then start the long-lived one.
wait_farm() {
  for _ in $(seq 180); do
    IROH_SECRET=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n') \
      dumbpipe connect-tcp --addr 127.0.0.1:5102 "$1" 2>/dev/null &
    local probe=$!
    sleep 3
    # Empty grpc.health.v1.HealthCheckRequest: 0 = uncompressed, 0 bytes.
    if printf '\0\0\0\0\0' | curl -fs -o /dev/null --max-time 10 --http2 \
      -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
      --cacert "$FARM_CRT" --cert "$FARM_CRT" --key "$state/farm.key" \
      https://127.0.0.1:5102/grpc.health.v1.Health/Check; then
      kill "$probe"
      return
    fi
    kill "$probe"
    sleep 5
  done
  echo "ci-farm: the farm did not come up" >&2
  exit 1
}

worker() {
  local i=${1:?worker index} farm
  farm=$(ticket farm)
  IROH_SECRET=$(derive "iroh-worker-$i") dumbpipe listen-tcp --host 127.0.0.1:5100 &
  wait_farm "$farm"
  echo "ci-farm: the farm is up"
  IROH_SECRET=$(derive "iroh-worker-dial-$i") \
    dumbpipe connect-tcp --addr 127.0.0.1:5101 "$farm" &
  "${daemon[@]}" --role builder --listen 127.0.0.1:5100 --scheduler 127.0.0.1:5101 \
    --advertise "127.0.0.1:$((5110 + i))" --worker-name "worker-$i" &
  local pid=$!
  until farm_done; do
    kill -0 "$pid" || exit 1
    sleep 15
  done
  # Drains: running builds finish and publish first.
  kill -TERM "$pid"
  wait "$pid" || true
}

cmd=${1:?usage: ci-farm farm MACHINE... | ci-farm worker INDEX}
shift
case $cmd in
farm) farm "$@" ;;
worker) worker "$@" ;;
*)
  echo "ci-farm: unknown command $cmd" >&2
  exit 1
  ;;
esac
