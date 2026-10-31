#!/usr/bin/env bash
# Packaging spike (plan PR-5): time from start to /api/health 200, memory, and a clean stop.
#
#   SIG=INT spike/backend/measure_start.sh <bundle>/python/bin <data-dir> <port>
#
# The backend starts with an empty environment (no PATH to a system Python), as a shell would start it.
set -u
bin=$1
data=$2
port=$3
log=$(mktemp)
home=$(mktemp -d)
start=$(date +%s.%N)
env -i HOME="$home" PATH=/usr/bin:/bin "$bin/nodestro" --no-browser --port "$port" --data-dir "$data" >"$log" 2>&1 &
pid=$!
until curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; do sleep 0.05; done
end=$(date +%s.%N)
rss=$(ps -o rss= -p "$pid")
kill -"${SIG:-INT}" "$pid"
wait "$pid"
code=$?
left=$(pgrep -f -- "--port $port" | wc -l)
echo "start_s=$(echo "$end - $start" | bc) rss_mb=$((rss / 1024)) exit=$code leftover=$left log=$log"
rm -rf "$home"
