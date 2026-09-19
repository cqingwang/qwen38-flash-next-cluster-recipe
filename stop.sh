#!/usr/bin/env bash
# 停止并删除 Qwen 四节点推理容器；模型和编译缓存保留。
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="${ENV_FILE:-.env}"
source "$ENV_FILE"

CONTAINER_HEAD="${CONTAINER_HEAD:-${NAME:-qwen38-flash-next-ablit-cluster}}"
CONTAINER_WORKER="${CONTAINER_WORKER:-$CONTAINER_HEAD}"
CONTAINER_WORKER2="${CONTAINER_WORKER2:-$CONTAINER_WORKER}"
CONTAINER_WORKER3="${CONTAINER_WORKER3:-$CONTAINER_WORKER2}"
WORKER_SSH="${WORKER_SSH:-}"
WORKER2_SSH="${WORKER2_SSH:-}"
WORKER3_SSH="${WORKER3_SSH:-}"

docker rm -f "$CONTAINER_HEAD" >/dev/null 2>&1 && echo "✓ head stopped" || echo "· head: not running"
stop_worker() {
  local rank="$1" target="$2" container="$3"
  [ -n "$target" ] || { echo "· worker rank=$rank: no SSH target"; return 0; }
  ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$target" "docker rm -f '$container' >/dev/null 2>&1" \
    && echo "✓ worker rank=$rank stopped ($target)" || echo "· worker rank=$rank: not running"
}
stop_worker 1 "$WORKER_SSH" "$CONTAINER_WORKER"
stop_worker 2 "$WORKER2_SSH" "$CONTAINER_WORKER2"
stop_worker 3 "$WORKER3_SSH" "$CONTAINER_WORKER3"
