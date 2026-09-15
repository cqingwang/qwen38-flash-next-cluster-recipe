#!/usr/bin/env bash
# Stop and remove the serve container on BOTH boxes. Weights and caches stay — ./run.sh brings it back fast.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=lib.sh
source lib.sh
docker rm -f "$NAME" >/dev/null 2>&1 && echo "✓ head stopped" || echo "· head: not running"
if [ -f .env ]; then
  # 总控受管模式：worker 地址来自 .env，不触发交互式 setup.sh。
  # shellcheck disable=SC1091
  source .env
  [ -n "${WORKER_SSH:-}" ] || { echo "· .env 没有 WORKER_SSH — worker untouched"; exit 0; }
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$WORKER_SSH" "docker rm -f '$NAME' >/dev/null 2>&1" \
    && echo "✓ worker stopped ($WORKER_SSH)" || echo "· worker: not running"
elif load_cluster 2>/dev/null; then
  ssh_w "docker rm -f '$NAME' >/dev/null 2>&1" && echo "✓ worker stopped ($WORKER_HOST)" || echo "· worker: not running"
else
  echo "· no cluster.env — worker untouched"
fi
