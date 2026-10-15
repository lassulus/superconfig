# shellcheck shell=bash
# (writeShellApplication adds the shebang and `set -euo pipefail`.)

# On-demand nix-grpc-store farm across GitHub Actions runners.
#
# Runners can't reach each other, so every hop goes through an iroh tunnel
# (dumbpipe) that ends on 127.0.0.1 on both sides:
#
#   farm job                                   machine job i
#   envoy :50051 ◄─────────────── iroh ─ :5103 ◄─ client (machine i)
#     ├─► daemon :50052 ◄──────── iroh ─ :5101 scheduler session
#     └─► :511i ───────────────── iroh ─► :5100 daemon (builder)
#   daemon :50052 (scheduler)
#
# Every daemon and envoy present the same TLS identity (FARM_KEY with
# farm.crt, SAN 127.0.0.1) and accept only it, as `trusted`. The iroh
# endpoint keys are derived from FARM_KEY, so it is the only secret. Outputs
# go to niks3 with the job's GitHub OIDC token, before a build counts as
# done, so a machine job can leave once its own machine is built.

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
# NIKS3_TOKEN_FILE at a niks3 API token instead. A failed fetch keeps the
# current token: `set -e` doesn't apply in `niks3_token || ...`, so every step
# returns explicitly.
niks3_token() {
  local token
  token=$(curl -fsS --retry 4 --retry-all-errors \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?needs id-token: write, or NIKS3_TOKEN_FILE}" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$niks3_url" | jq -er .value) || return 1
  [ -n "$token" ] || return 1
  printf '%s\n' "$token" >"$state/niks3-token.new" &&
    mv "$state/niks3-token.new" "$state/niks3-token"
}
# Refreshes every 2 minutes, every 20 seconds after a failure. The token is
# valid for 5 minutes: once it is 4 minutes old a builder (machine writes
# builder.pid) could not publish its outputs anymore, so drain it, and the
# scheduler hands its builds to the others.
refresh_niks3_token() {
  local fetched=$SECONDS wait=120
  while sleep "$wait"; do
    if niks3_token; then
      fetched=$SECONDS wait=120
      continue
    fi
    wait=20
    echo "ci-farm: refreshing the niks3 token failed, it is $((SECONDS - fetched))s old" >&2
    if [ $((SECONDS - fetched)) -ge 240 ] && [ -s "$state/builder.pid" ]; then
      echo "ci-farm: no fresh niks3 token, draining the builder" >&2
      kill -TERM "$(<"$state/builder.pid")" 2>/dev/null || true
      rm -f "$state/builder.pid"
    fi
  done
}
if [ -n "${NIKS3_TOKEN_FILE:-}" ]; then
  ln -sf "$NIKS3_TOKEN_FILE" "$state/niks3-token"
else
  niks3_token
  refresh_niks3_token &
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

# The jobs NAME... of this run have all finished. In a workflow called from
# another (ci.yml) the API names them "<caller job> / NAME". Outside Actions
# there are no jobs to watch: never.
jobs_done() {
  local jobs name
  [ -n "${GITHUB_RUN_ID:-}" ] || return 1
  jobs=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?per_page=100" \
    --jq '.jobs[] | "\(.status) \(.name | sub("^.* / "; ""))"') || return 1
  for name in "$@"; do
    grep -qxF "completed $name" <<<"$jobs" || return 1
  done
}

# ci-farm farm MACHINE...: scheduler and balancer for the machine jobs
# (builder i builds the i-th MACHINE), until they have all finished.
farm() {
  local i port clusters
  "${daemon[@]}" --role scheduler --listen 127.0.0.1:50052 2>"$state/daemon.log" &
  local pid=$!
  tail -f "$state/daemon.log" >&2 &
  envoy -c "$ENVOY_CONFIG" --log-level warn &
  wait_http http://127.0.0.1:9901/ready
  # A daemon without the builder role schedules only once niks3 has made it
  # the leader.
  for _ in $(seq 60); do
    grep -q event=scheduler_take_over "$state/daemon.log" && break
    sleep 2
  done
  if ! grep -q event=scheduler_take_over "$state/daemon.log"; then
    echo "ci-farm: the scheduler did not get the lead from niks3" >&2
    exit 1
  fi
  IROH_SECRET=$(derive iroh-farm) dumbpipe listen-tcp --host 127.0.0.1:50052 &
  IROH_SECRET=$(derive iroh-lb) dumbpipe listen-tcp --host 127.0.0.1:50051 &
  echo "ci-farm: the farm is up"

  # Builder i shows up in envoy's clusters once its scheduler session is up,
  # i.e. its own iroh endpoint is online. Only then dial it (a dialer started
  # before the endpoint is discoverable never reaches it), and dial again
  # when the tunnel dies or envoy's health checks fail through it for a
  # minute.
  declare -A dialers=() since=()
  until jobs_done "$@"; do
    kill -0 "$pid" || exit 1
    clusters=$(curl -fs http://127.0.0.1:9901/clusters) || clusters=
    for i in $(seq $#); do
      port=$((5110 + i))
      grep -qF "::127.0.0.1:$port::health_flags::" <<<"$clusters" || continue
      if [ -n "${dialers[$i]:-}" ] && kill -0 "${dialers[$i]}" 2>/dev/null; then
        if grep -qxE ".*::127\.0\.0\.1:$port::health_flags::healthy" <<<"$clusters"; then
          since[$i]=$SECONDS
          continue
        fi
        [ $((SECONDS - since[$i])) -lt 60 ] && continue
        kill "${dialers[$i]}" 2>/dev/null || true
      fi
      IROH_SECRET=$(derive "iroh-farm-dial-$i") \
        dumbpipe connect-tcp --addr "127.0.0.1:$port" "$(ticket "worker-$i")" &
      dialers[$i]=$!
      since[$i]=$SECONDS
    done
    sleep 15
  done
}

# grpc.health.v1 Check on 127.0.0.1:PORT over the farm's TLS, prints the
# response headers and trailers. An empty HealthCheckRequest: 0 = uncompressed,
# 0 bytes.
health() {
  printf '\0\0\0\0\0' | curl -s -o /dev/null -D - --max-time 10 --http2 \
    -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
    --cacert "$FARM_CRT" --cert "$FARM_CRT" --key "$state/farm.key" \
    "https://127.0.0.1:$1/grpc.health.v1.Health/Check"
}

# A dumbpipe dialer started before the farm is discoverable never reaches it,
# not even once the farm is online. Probe PORT with short-lived dialers to
# TICKET until it answers an HTTP/2 request over the farm's TLS, then leave
# the long-lived dialer to the caller. Gives up once the farm job has
# finished (checked every 2 minutes, the API is rate limited).
wait_farm() {
  local port=$1 ticket=$2 probe n=0
  while true; do
    IROH_SECRET=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n') \
      dumbpipe connect-tcp --addr "127.0.0.1:$port" "$ticket" 2>/dev/null &
    probe=$!
    sleep 3
    if health "$port" >/dev/null; then
      kill "$probe" 2>/dev/null || true
      return
    fi
    kill "$probe" 2>/dev/null || true
    sleep 5
    n=$((n + 1))
    if [ $((n % 15)) -eq 0 ] && jobs_done coordinator; then
      echo "ci-farm: the farm did not come up" >&2
      exit 1
    fi
  done
}

# Envoy (via PORT) has a builder to send requests to only once one has joined
# the scheduler and the farm has dialed it and health checked it through the
# tunnel; until then it answers itself, with grpc-status 14 ("no healthy
# upstream", or "remote connection failure" for a builder not dialed yet).
# A client gives up on a store it has never reached, so wait until a health
# check through envoy reaches a builder (grpc-status 0). Gives up when the
# builder PID dies or the farm job has finished, like wait_farm.
wait_builder() {
  local port=$1 pid=$2 n=0
  until health "$port" | grep -qE '^grpc-status: 0\s*$'; do
    kill -0 "$pid" 2>/dev/null || exit 1
    sleep 5
    n=$((n + 1))
    if [ $((n % 24)) -eq 0 ] && jobs_done coordinator; then
      echo "ci-farm: the farm has no builder" >&2
      exit 1
    fi
  done
}

# ci-farm machine INDEX NAME: builder INDEX of the farm (NAME is the farm's
# INDEX-th MACHINE) while it builds the toplevel of NAME through the farm.
# Leaves once that is done: draining finishes its running builds, whose
# outputs are in niks3 then, and the scheduler hands the rest to the others.
machine() {
  local i=${1:?machine index} name=${2:?machine name} farm lb eval pid status=0
  farm=$(ticket farm)
  lb=$(ticket lb)
  nix eval --raw ".#nixosConfigurations.$name.config.system.build.toplevel.drvPath" >"$state/drv" &
  eval=$!
  IROH_SECRET=$(derive "iroh-worker-$i") dumbpipe listen-tcp --host 127.0.0.1:5100 &
  wait_farm 5102 "$farm"
  wait_farm 5104 "$lb"
  echo "ci-farm: the farm is up"
  IROH_SECRET=$(derive "iroh-worker-dial-$i") \
    dumbpipe connect-tcp --addr 127.0.0.1:5101 "$farm" &
  IROH_SECRET=$(derive "iroh-worker-lb-$i") \
    dumbpipe connect-tcp --addr 127.0.0.1:5103 "$lb" &
  "${daemon[@]}" --role builder --listen 127.0.0.1:5100 --scheduler 127.0.0.1:5101 \
    --advertise "127.0.0.1:$((5110 + i))" --worker-name "$name" &
  pid=$!
  echo "$pid" >"$state/builder.pid"

  if wait "$eval"; then
    echo "ci-farm: $name: $(<"$state/drv")"
    wait_builder 5103 "$pid"
    "$NIX_WITH_PLUGIN" build --no-link --print-out-paths --eval-store auto \
      --store "grpc://127.0.0.1:5103?system=x86_64-linux&ca-cert=$FARM_CRT&client-cert=$FARM_CRT&client-key=$state/farm.key" \
      "$(<"$state/drv")^*" || status=$?
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || echo "ci-farm: $name failed" >&2

  # Drains: running builds finish and publish first.
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" || true
  return "$status"
}

# ci-farm push PATH...: pushes the closures of PATH... to niks3, e.g. the
# farm's own closure, which no other cache has.
push() {
  niks3 push --server-url "$niks3_url" --auth-token-path "$state/niks3-token" \
    --ignore-upstream-key cache.nixos.org-1 "$@"
}

cmd=${1:?usage: ci-farm farm MACHINE... | ci-farm machine INDEX NAME | ci-farm push PATH...}
shift
case $cmd in
farm) farm "$@" ;;
machine) machine "$@" ;;
push) push "$@" ;;
*)
  echo "ci-farm: unknown command $cmd" >&2
  exit 1
  ;;
esac
