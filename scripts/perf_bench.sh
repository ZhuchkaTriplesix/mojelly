#!/bin/bash
# Load-test a built Mojelly server with oha and write the result as JSON.
#
# Usage: scripts/perf_bench.sh <dir-with-built-server> <result.json>
#
# Env (all optional):
#   PERF_PATH         endpoint to hit              (default /json)
#   PERF_DURATION     measured run, seconds        (default 30)
#   PERF_WARMUP       warmup run, seconds          (default 5)
#   PERF_CONNECTIONS  concurrent connections       (default 100)
#   PERF_CLIENT_CPUS  taskset cpu list for oha     (default: unpinned)
#   PERF_PORT         server port                  (default 8080)
set -euo pipefail

DIR="${1:?usage: perf_bench.sh <server-dir> <result.json>}"
OUT="${2:?usage: perf_bench.sh <server-dir> <result.json>}"

OUT="$(realpath -m "$OUT")"  # resolve before cd below

PATH_="${PERF_PATH:-/json}"
DURATION="${PERF_DURATION:-30}"
WARMUP="${PERF_WARMUP:-5}"
CONNS="${PERF_CONNECTIONS:-100}"
PORT="${PERF_PORT:-8080}"

# The server is not pinned here: its worker threads pin themselves to
# CPUs 0..N-1 (see thread_main in src_c), which overrides any taskset mask.
client() {
    if [ -n "${PERF_CLIENT_CPUS:-}" ]; then
        taskset -c "$PERF_CLIENT_CPUS" oha "$@"
    else
        oha "$@"
    fi
}

cd "$DIR"

# Servers bind with SO_REUSEPORT, so a leftover one would silently share the load.
if curl -s -o /dev/null "http://localhost:$PORT/"; then
    echo "port $PORT is already serving; stop the other server first" >&2
    exit 1
fi

# Launched directly (no wrapper function/subshell) so that $! is the server
# itself and the EXIT trap really stops it. Per-request logs go to stdout
# and would grow by hundreds of MB, so only stderr is kept.
./server > /dev/null 2> server.log &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 50); do
    if curl -fs -o /dev/null "http://localhost:$PORT/"; then ready=1; break; fi
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "server died:" >&2; cat server.log >&2; exit 1; }
    sleep 0.2
done
[ "$ready" = 1 ] || { echo "server did not become ready" >&2; cat server.log >&2; exit 1; }

URL="http://localhost:$PORT$PATH_"
client -z "${WARMUP}s" -c "$CONNS" --no-tui "$URL" > /dev/null 2>&1
client -z "${DURATION}s" -c "$CONNS" --no-tui \
    --output-format json "$URL" > oha.json

jq '{rps: .summary.requestsPerSec,
     p99_ms: (.latencyPercentiles.p99 * 1000),
     success_rate: .summary.successRate}' oha.json > "$OUT"
cat "$OUT"
