#!/usr/bin/env bash
# 停止并删除 Qwen 四节点推理容器；模型和编译缓存保留。
set -euo pipefail
cd "$(dirname "$0")"
ENV_FILE="${ENV_FILE:-.env}"
source "$ENV_FILE"

TARGET_ENGINE_ID="${TARGET_ENGINE_ID:-qwen3.8_flash_switchless}"
TARGET_CONTAINER_PREFIX="${TARGET_CONTAINER_PREFIX:-$TARGET_ENGINE_ID}"
NNODES="${NNODES:-4}"
WORKER_SSH="${WORKER_SSH:-}"
WORKER2_SSH="${WORKER2_SSH:-}"
WORKER3_SSH="${WORKER3_SSH:-}"

rank_container_name() { printf '%s-r%s' "$TARGET_CONTAINER_PREFIX" "$1"; }

head_container="$(rank_container_name 0)"
docker rm -f "$head_container" >/dev/null 2>&1 && echo "✓ head stopped" || echo "· head: not running"
stop_worker() {
  local rank="$1" target="$2" container="$3"
  [ -n "$target" ] || { echo "· worker rank=$rank: no SSH target"; return 0; }
  ssh -T -o BatchMode=yes -o ConnectTimeout=8 "$target" "docker rm -f '$container' >/dev/null 2>&1" \
    && echo "✓ worker rank=$rank stopped ($target)" || echo "· worker rank=$rank: not running"
}
stop_worker 1 "$WORKER_SSH" "$(rank_container_name 1)"
if [ "$NNODES" = 4 ]; then
  stop_worker 2 "$WORKER2_SSH" "$(rank_container_name 2)"
  stop_worker 3 "$WORKER3_SSH" "$(rank_container_name 3)"
fi
