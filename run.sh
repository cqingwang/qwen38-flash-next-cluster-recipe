#!/usr/bin/env bash
# qwen3.8_flash_ablit 双节点启动器。
# 受管模式只使用总控注入的宿主机绝对模型路径：不下载、不复制、不创建 HF cache 视图。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib.sh
source lib.sh

info() { echo "[INFO] $*"; }
ok() { echo "[ OK ] $*"; }
fail() { echo "[ERR ] $*" >&2; exit 1; }

[ -f .env ] || fail "缺少 .env；请从 /opt/spark/deploy.sh start 生成受管配置"
# shellcheck disable=SC1091
source .env

MODEL_PATH="${MODEL_PATH:-}"
CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-/models}"
MODEL_ID="${MODEL_ID:-}"
HEAD_IP="${HEAD_IP:-}"
WORKER_IP="${WORKER_IP:-}"
WORKER_SSH="${WORKER_SSH:-}"
IFACE="${IFACE:-}"
WORKER_IFACE="${WORKER_IFACE:-$IFACE}"
IB_HCA="${IB_HCA:-}"
WORKER_IB_HCA="${WORKER_IB_HCA:-$IB_HCA}"
IB_GID_INDEX="${IB_GID_INDEX:-3}"
API_HOST="${API_HOST:-127.0.0.1}"
PORT="${PORT:-8888}"
MASTER_PORT="${MASTER_PORT:-25000}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-2}"
NNODES="${NNODES:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-$(rkey vllm max-model-len)}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$MODEL_ID}"
IMAGE="${IMAGE:-$(rkey server image)}"
CPUSET="${CPUSET:-$(rkey server cpuset)}"
RUNTIME_ASSETS="${RUNTIME_ASSETS:-/opt/models/runtime_assets}"
CACHE_DIR="${CACHE_DIR:-$RUNTIME_ASSETS/qwen3.8_flash_ablit}"
NAME="${NAME:-qwen38-flash-next-ablit-cluster}"

for required in MODEL_PATH MODEL_ID HEAD_IP WORKER_IP WORKER_SSH IFACE IB_HCA IMAGE MAX_MODEL_LEN SERVED_MODEL_NAME; do
  [ -n "${!required:-}" ] || fail "缺少必需配置: $required"
done
case "$MODEL_PATH" in /*) ;; *) fail "MODEL_PATH 必须是宿主机绝对路径: $MODEL_PATH" ;; esac
[ -d "$MODEL_PATH" ] || fail "head 模型目录不存在: $MODEL_PATH"
[ ! -L "$MODEL_PATH" ] || fail "MODEL_PATH 不能是符号链接: $MODEL_PATH"
[ -f "$MODEL_PATH/config.json" ] || fail "模型缺少 config.json: $MODEL_PATH"
[ -f "$MODEL_PATH/model.safetensors.index.json" ] || fail "模型缺少 safetensors 索引: $MODEL_PATH"
case "$CONTAINER_MODEL_PATH" in /*) ;; *) fail "CONTAINER_MODEL_PATH 必须是绝对路径" ;; esac

ssh_worker() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$WORKER_SSH" "$@"; }
remote_model_q="$(printf '%q' "$MODEL_PATH")"
ssh_worker "test -d $remote_model_q && test ! -L $remote_model_q && test -f $remote_model_q/config.json && test -f $remote_model_q/model.safetensors.index.json" \
  || fail "worker 缺少同一真实模型目录或索引: $MODEL_PATH"
ok "两端模型已预置: $MODEL_PATH（不复制）"

mkdir -p "$CACHE_DIR"
ssh_worker "mkdir -p '$CACHE_DIR'"

ensure_image() {
  local side="$1"
  if [ "$side" = head ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
  else
    ssh_worker "docker image inspect '$IMAGE' >/dev/null 2>&1 || docker pull -q '$IMAGE' >/dev/null"
  fi
}
ensure_image head || fail "head 无法准备镜像: $IMAGE"
ensure_image worker || fail "worker 无法准备镜像: $IMAGE"

ENVS=(-e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_CACHE_ROOT=/cache/vllm-cache)
while IFS=$'\t' read -r key value; do
  [ -n "$key" ] && ENVS+=(-e "$key=$value")
done < <(rsection env)

FLAGS=()
while IFS=$'\t' read -r key value; do
  case "$key" in
    max-model-len|served-model-name) continue ;;
  esac
  case "$value" in
    true) FLAGS+=("--$key") ;;
    false|null|"") ;;
    *) FLAGS+=("--$key" "$value") ;;
  esac
done < <(rsection vllm)
FLAGS+=(--max-model-len "$MAX_MODEL_LEN" --served-model-name "$SERVED_MODEL_NAME")

compose() {
  local rank="$1" iface="$2" ic="$3" hca="$4" a=()
  a=(docker run -d --name "$NAME" --gpus all --ipc=host --network host --cap-add SYS_PTRACE)
  [ -d /dev/infiniband ] && a+=(--device /dev/infiniband --cap-add IPC_LOCK --ulimit memlock=-1:-1)
  [ -n "$CPUSET" ] && a+=(--cpuset-cpus "$CPUSET")
  # 模型目录是唯一权重来源，必须保留只读挂载；缓存与权重完全分离。
  a+=(-v "$MODEL_PATH:$CONTAINER_MODEL_PATH:ro" -v "$CACHE_DIR:/cache")
  a+=("${ENVS[@]}" -e "NCCL_SOCKET_IFNAME=$iface" -e "GLOO_SOCKET_IFNAME=$iface"
      -e "VLLM_HOST_IP=$ic" -e "NCCL_IB_HCA=$hca" -e "NCCL_IB_GID_INDEX=$IB_GID_INDEX"
      -e NCCL_IB_DISABLE=0 --entrypoint vllm "$IMAGE" serve "$CONTAINER_MODEL_PATH"
      --host "$API_HOST" --port "$PORT" --nnodes "$NNODES" --node-rank "$rank"
      --master-addr "$HEAD_IP" --master-port "$MASTER_PORT"
      --tensor-parallel-size "$TENSOR_PARALLEL_SIZE")
  [ "$rank" != 0 ] && a+=(--headless)
  a+=("${FLAGS[@]}")
  printf '%q ' "${a[@]}"
}

docker rm -f "$NAME" >/dev/null 2>&1 || true
ssh_worker "docker rm -f '$NAME' >/dev/null 2>&1 || true"
info "启动 head rank=0，API=${API_HOST}:${PORT}，模型=${MODEL_ID}"
eval "$(compose 0 "$IFACE" "$HEAD_IP" "$IB_HCA")" >/dev/null
sleep 2
info "启动 worker rank=1（${WORKER_SSH}）"
ssh_worker "$(compose 1 "$WORKER_IFACE" "$WORKER_IP" "$WORKER_IB_HCA") >/dev/null"

CHECK_HOST="$API_HOST"
[ "$CHECK_HOST" = 0.0.0.0 ] && CHECK_HOST=127.0.0.1
for _ in $(seq 1 360); do
  if curl -sf -m 3 "http://${CHECK_HOST}:${PORT}/health" >/dev/null 2>&1; then
    ok "双节点服务健康: http://${API_HOST}:${PORT}/v1"
    exit 0
  fi
  if ! docker ps -q --filter "name=^${NAME}$" | grep -q .; then
    docker logs --tail 80 "$NAME" >&2 || true
    fail "head 容器已退出"
  fi
  if ! ssh_worker "docker ps -q --filter 'name=^$NAME\$' | grep -q ." 2>/dev/null; then
    ssh_worker "docker logs --tail 80 '$NAME'" >&2 || true
    fail "worker 容器已退出"
  fi
  sleep 5
done
fail "服务在 30 分钟内未通过 /health；请查看 docker logs $NAME"
