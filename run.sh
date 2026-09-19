#!/usr/bin/env bash
# Qwen3.8-Flash 唯一启动源码；TP2/TP4 拓扑和参数只由目标配置目录的受管 .env 决定。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
RECIPE_FILE="${RECIPE_FILE:-$SCRIPT_DIR/recipe.yaml}"
source lib.sh
info() { echo "[INFO] $*"; }
ok() { echo "[ OK ] $*"; }
fail() { echo "[ERR ] $*" >&2; exit 1; }

ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || fail "缺少环境文件：$ENV_FILE；请从 /opt/spark/deploy.sh start 生成受管配置"
source "$ENV_FILE"

MODEL_PATH="${MODEL_PATH:-}"
CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH:-/models}"
MODEL_ID="${MODEL_ID:-}"
TARGET_ENGINE_ID="${TARGET_ENGINE_ID:-qwen3.8_flash_switchless}"
HEAD_IP="${HEAD_IP:-}"
WORKER_IP="${WORKER_IP:-}"
WORKER2_IP="${WORKER2_IP:-}"
WORKER3_IP="${WORKER3_IP:-}"
WORKER_SSH="${WORKER_SSH:-}"
WORKER2_SSH="${WORKER2_SSH:-}"
WORKER3_SSH="${WORKER3_SSH:-}"
HEAD_FABRIC_IFACES="${HEAD_FABRIC_IFACES:-}"
WORKER_FABRIC_IFACES="${WORKER_FABRIC_IFACES:-}"
WORKER2_FABRIC_IFACES="${WORKER2_FABRIC_IFACES:-$WORKER_FABRIC_IFACES}"
WORKER3_FABRIC_IFACES="${WORKER3_FABRIC_IFACES:-$WORKER2_FABRIC_IFACES}"
HEAD_SOCKET_IFACE="${HEAD_SOCKET_IFACE:-${IFACE:-}}"
WORKER_SOCKET_IFACE="${WORKER_SOCKET_IFACE:-$HEAD_SOCKET_IFACE}"
WORKER2_SOCKET_IFACE="${WORKER2_SOCKET_IFACE:-$WORKER_SOCKET_IFACE}"
WORKER3_SOCKET_IFACE="${WORKER3_SOCKET_IFACE:-$WORKER2_SOCKET_IFACE}"
HEAD_HCA="${HEAD_HCA:-${IB_HCA:-}}"
WORKER_HCA="${WORKER_HCA:-${WORKER_IB_HCA:-}}"
WORKER2_HCA="${WORKER2_HCA:-$WORKER_HCA}"
WORKER3_HCA="${WORKER3_HCA:-$WORKER2_HCA}"
PEER_HCA_RANK0="${PEER_HCA_RANK0:-}"
PEER_HCA_RANK1="${PEER_HCA_RANK1:-}"
PEER_HCA_RANK2="${PEER_HCA_RANK2:-}"
PEER_HCA_RANK3="${PEER_HCA_RANK3:-}"
NCCL_IB_GID_INDEX_FORCE="${NCCL_IB_GID_INDEX_FORCE:-}"
IB_GID_INDEX="${NCCL_IB_GID_INDEX_FORCE:-${NCCL_IB_GID_INDEX:-${IB_GID_INDEX:-3}}}"
NCCL_NET="${NCCL_NET:-IB}"
NCCL_NET_PLUGIN="${NCCL_NET_PLUGIN:-none}"
NCCL_ALGO="${NCCL_ALGO:-RING}"
NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE:-1}"
NCCL_SHM_DISABLE="${NCCL_SHM_DISABLE:-1}"
NCCL_CROSS_NIC="${NCCL_CROSS_NIC:-1}"
NCCL_IB_MERGE_NICS="${NCCL_IB_MERGE_NICS:-0}"
NCCL_IB_SUBNET_AWARE_ROUTING="${NCCL_IB_SUBNET_AWARE_ROUTING:-1}"
NCCL_IB_TIMEOUT="${NCCL_IB_TIMEOUT:-1000}"
NCCL_IB_RETRY_CNT="${NCCL_IB_RETRY_CNT:-7}"
NCCL_IB_TOS="${NCCL_IB_TOS:-46}"
NCCL_MIN_NCHANNELS="${NCCL_MIN_NCHANNELS:-4}"
NCCL_MAX_NCHANNELS="${NCCL_MAX_NCHANNELS:-4}"
NCCL_BUFFSIZE="${NCCL_BUFFSIZE:-8388608}"
NCCL_SET_THREAD_NAME="${NCCL_SET_THREAD_NAME:-1}"
NCCL_TUNER_THRESHOLD="${NCCL_TUNER_THRESHOLD:-40960}"
NCCL_CUMEM_HOST_ENABLE="${NCCL_CUMEM_HOST_ENABLE:-0}"
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-}"
API_HOST="${API_HOST:-0.0.0.0}"
PORT="${PORT:-8888}"
MASTER_PORT="${MASTER_PORT:-25000}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-4}"
NNODES="${NNODES:-4}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-$(rkey vllm max-model-len)}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$MODEL_ID}"
IMAGE="${IMAGE:-$(rkey server image)}"
CPUSET="${CPUSET:-$(rkey server cpuset)}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/qwen38-flash-next}"
USE_HOST_NCCL="${USE_HOST_NCCL:-1}"
NCCL_HOST_DIR="${NCCL_HOST_DIR:-/opt/nccl-ringonly}"
NCCL_CONTAINER_DIR="${NCCL_CONTAINER_DIR:-/nccl}"
NCCL_SO_NAME="${NCCL_SO_NAME:-libnccl.so.2}"
NCCL_PIN_HOST="${NCCL_PIN_HOST:-/opt/aicad-prod/lib/libncclpin.so}"
NCCL_PIN_CONTAINER="${NCCL_PIN_CONTAINER:-/opt/libncclpin.so}"
if [ "$NNODES" = 2 ]; then
  CONTAINER_HEAD="${CONTAINER_HEAD:-qwen38-flash-next-duo-tp2-head}"
  CONTAINER_WORKER="${CONTAINER_WORKER:-qwen38-flash-next-duo-tp2-worker}"
else
  CONTAINER_HEAD="${CONTAINER_HEAD:-qwen38-flash-next-switchless-tp4-head}"
  CONTAINER_WORKER="${CONTAINER_WORKER:-qwen38-flash-next-switchless-tp4-w1}"
  CONTAINER_WORKER2="${CONTAINER_WORKER2:-qwen38-flash-next-switchless-tp4-w2}"
  CONTAINER_WORKER3="${CONTAINER_WORKER3:-qwen38-flash-next-switchless-tp4-w3}"
fi

case "$NNODES:$TENSOR_PARALLEL_SIZE" in
  2:2|4:4) ;;
  *) fail "Qwen 唯一启动器只支持 TP2/NNODES=2 或 TP4/NNODES=4，实际为 NNODES=$NNODES TP=$TENSOR_PARALLEL_SIZE" ;;
esac
for required in MODEL_PATH MODEL_ID HEAD_IP WORKER_IP WORKER_SSH IMAGE MAX_MODEL_LEN SERVED_MODEL_NAME HEAD_SOCKET_IFACE HEAD_HCA; do
  [ -n "${!required:-}" ] || fail "缺少必需配置: $required"
done
if [ "$NNODES" = 4 ]; then
  for required in WORKER2_IP WORKER3_IP WORKER2_SSH WORKER3_SSH; do
    [ -n "${!required:-}" ] || fail "TP4 缺少必需配置: $required"
  done
fi
case "$MODEL_PATH" in /*) ;; *) fail "MODEL_PATH 必须是宿主机绝对路径: $MODEL_PATH" ;; esac
[ -d "$MODEL_PATH" ] || fail "head 模型目录不存在: $MODEL_PATH"
[ ! -L "$MODEL_PATH" ] || fail "MODEL_PATH 不能是符号链接: $MODEL_PATH"
[ -f "$MODEL_PATH/config.json" ] || fail "模型缺少 config.json: $MODEL_PATH"
[ -f "$MODEL_PATH/model.safetensors.index.json" ] || fail "模型缺少 safetensors 索引: $MODEL_PATH"
case "$CONTAINER_MODEL_PATH" in /*) ;; *) fail "CONTAINER_MODEL_PATH 必须是绝对路径" ;; esac

worker_ssh_rank() {
  case "$1" in
    1) shift; ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$WORKER_SSH" "$@" ;;
    2) shift; ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$WORKER2_SSH" "$@" ;;
    3) shift; ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$WORKER3_SSH" "$@" ;;
    *) fail "非法 worker rank: $1" ;;
  esac
}

rank_value() {
  local rank="$1" field="$2"
  case "$field:$rank" in
    ip:0) printf '%s' "$HEAD_IP" ;; ip:1) printf '%s' "$WORKER_IP" ;; ip:2) printf '%s' "$WORKER2_IP" ;; ip:3) printf '%s' "$WORKER3_IP" ;;
    socket:0) printf '%s' "$HEAD_SOCKET_IFACE" ;; socket:1) printf '%s' "$WORKER_SOCKET_IFACE" ;; socket:2) printf '%s' "$WORKER2_SOCKET_IFACE" ;; socket:3) printf '%s' "$WORKER3_SOCKET_IFACE" ;;
    hca:0) printf '%s' "$HEAD_HCA" ;; hca:1) printf '%s' "$WORKER_HCA" ;; hca:2) printf '%s' "$WORKER2_HCA" ;; hca:3) printf '%s' "$WORKER3_HCA" ;;
    peer:0) printf '%s' "$PEER_HCA_RANK0" ;; peer:1) printf '%s' "$PEER_HCA_RANK1" ;; peer:2) printf '%s' "$PEER_HCA_RANK2" ;; peer:3) printf '%s' "$PEER_HCA_RANK3" ;;
    fabric:0) printf '%s' "$HEAD_FABRIC_IFACES" ;; fabric:1) printf '%s' "$WORKER_FABRIC_IFACES" ;; fabric:2) printf '%s' "$WORKER2_FABRIC_IFACES" ;; fabric:3) printf '%s' "$WORKER3_FABRIC_IFACES" ;;
    container:0) printf '%s' "$CONTAINER_HEAD" ;; container:1) printf '%s' "$CONTAINER_WORKER" ;; container:2) printf '%s' "$CONTAINER_WORKER2" ;; container:3) printf '%s' "$CONTAINER_WORKER3" ;;
    *) fail "非法 rank/字段: $field:$rank" ;;
  esac
}

rank_model_path() {
  case "$1" in
    0) printf '%s' "$MODEL_PATH" ;;
    1) printf '%s' "${WORKER_MODEL_PATH:-$MODEL_PATH}" ;;
    2) printf '%s' "${WORKER2_MODEL_PATH:-${WORKER_MODEL_PATH:-$MODEL_PATH}}" ;;
    3) printf '%s' "${WORKER3_MODEL_PATH:-${WORKER2_MODEL_PATH:-${WORKER_MODEL_PATH:-$MODEL_PATH}}}" ;;
    *) fail "非法 rank: $1" ;;
  esac
}

rank_cache_dir() {
  case "$1" in
    0) printf '%s' "$CACHE_DIR" ;;
    1) printf '%s' "${WORKER_CACHE_DIR:-$CACHE_DIR}" ;;
    2) printf '%s' "${WORKER2_CACHE_DIR:-${WORKER_CACHE_DIR:-$CACHE_DIR}}" ;;
    3) printf '%s' "${WORKER3_CACHE_DIR:-${WORKER2_CACHE_DIR:-${WORKER_CACHE_DIR:-$CACHE_DIR}}}" ;;
    *) fail "非法 rank: $1" ;;
  esac
}

rank_nccl_dir() {
  case "$1" in
    0) printf '%s' "$NCCL_HOST_DIR" ;;
    1) printf '%s' "${WORKER_NCCL_HOST_DIR:-$NCCL_HOST_DIR}" ;;
    2) printf '%s' "${WORKER2_NCCL_HOST_DIR:-${WORKER_NCCL_HOST_DIR:-$NCCL_HOST_DIR}}" ;;
    3) printf '%s' "${WORKER3_NCCL_HOST_DIR:-${WORKER2_NCCL_HOST_DIR:-${WORKER_NCCL_HOST_DIR:-$NCCL_HOST_DIR}}}" ;;
    *) fail "非法 rank: $1" ;;
  esac
}

check_rank_assets() {
  local rank="$1" path quoted
  path="$(rank_model_path "$rank")"
  case "$path" in /*) ;; *) fail "rank $rank 的模型路径不是绝对路径: $path" ;; esac
  if [ "$rank" = 0 ]; then
    [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/config.json" ] && [ -f "$path/model.safetensors.index.json" ] \
      || fail "rank 0 模型目录或索引不完整: $path"
    return 0
  fi
  printf -v quoted '%q' "$path"
  worker_ssh_rank "$rank" "test -d $quoted && test ! -L $quoted && test -f $quoted/config.json && test -f $quoted/model.safetensors.index.json" \
    || fail "rank $rank 缺少同一真实模型目录或索引: $path"
}

check_rank_image() {
  local rank="$1" nccl_dir
  if [ "$rank" = 0 ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
  else
    worker_ssh_rank "$rank" "docker image inspect '$IMAGE' >/dev/null 2>&1 || docker pull -q '$IMAGE' >/dev/null" \
      || fail "rank $rank 无法准备镜像: $IMAGE"
  fi
  [ "$USE_HOST_NCCL" = 1 ] || return 0
  nccl_dir="$(rank_nccl_dir "$rank")"
  if [ "$rank" = 0 ]; then
    [ -f "$nccl_dir/$NCCL_SO_NAME" ] || fail "rank 0 缺少 ring-only NCCL: $nccl_dir/$NCCL_SO_NAME"
    [ -f "$NCCL_PIN_HOST" ] || fail "rank 0 缺少 NCCL pin shim: $NCCL_PIN_HOST"
  else
    worker_ssh_rank "$rank" "test -f '$nccl_dir/$NCCL_SO_NAME' && test -f '$NCCL_PIN_HOST'" \
      || fail "rank $rank 缺少 ring-only NCCL 或 pin shim"
  fi
}

check_rank_fabric() {
  local rank="$1" fabric_ifaces iface remote_command
  fabric_ifaces="$(rank_value "$rank" fabric | tr ',' ' ')"
  [ -n "$fabric_ifaces" ] || fail "rank $rank 缺少物理环 fabric 网卡配置"
  if [ "$rank" = 0 ]; then
    for iface in $fabric_ifaces; do
      [ -d "/sys/class/net/$iface/device/infiniband" ] \
        || fail "rank 0 fabric 网卡未绑定 RDMA 设备: $iface"
    done
    return 0
  fi
  remote_command="for iface in $fabric_ifaces; do test -d /sys/class/net/\$iface/device/infiniband || exit 1; done"
  worker_ssh_rank "$rank" "$remote_command" \
    || fail "rank $rank fabric 网卡未绑定 RDMA 设备: $fabric_ifaces"
}

build_flags() {
  local key value
  FLAGS=()
  while IFS=$'\t' read -r key value; do
    case "$key" in max-model-len|served-model-name) continue ;; esac
    case "$value" in true) FLAGS+=("--$key") ;; false|null|"") ;; *) FLAGS+=("--$key" "$value") ;; esac
  done < <(rsection vllm)
  FLAGS+=(--max-model-len "$MAX_MODEL_LEN" --served-model-name "$SERVED_MODEL_NAME")
}

compose_rank() {
  local rank="$1" container path cache socket ip hca peer nccl
  local -a command env_args
  container="$(rank_value "$rank" container)"
  path="$(rank_model_path "$rank")"
  cache="$(rank_cache_dir "$rank")"
  socket="$(rank_value "$rank" socket)"
  ip="$(rank_value "$rank" ip)"
  hca="$(rank_value "$rank" hca)"
  peer="$(rank_value "$rank" peer)"
  nccl="$(rank_nccl_dir "$rank")"
  [ -n "$hca" ] || fail "rank $rank 缺少 NCCL_IB_HCA"
  [ -n "$peer" ] || fail "rank $rank 缺少 PEER_HCA_RANK$rank"
  command=(docker run -d --name "$container" --gpus all --ipc=host --network host --cap-add SYS_PTRACE)
  [ -d /dev/infiniband ] && command+=(--device /dev/infiniband --cap-add IPC_LOCK --ulimit memlock=-1:-1)
  [ -n "$CPUSET" ] && command+=(--cpuset-cpus "$CPUSET")
  command+=(-v "$path:$CONTAINER_MODEL_PATH:ro" -v "$cache:/cache")
  if [ "$USE_HOST_NCCL" = 1 ]; then
    command+=(--ulimit memlock=-1:-1 -v "$nccl:$NCCL_CONTAINER_DIR:ro" -v "$NCCL_PIN_HOST:$NCCL_PIN_CONTAINER:ro")
  fi
  env_args=(-e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_CACHE_ROOT=/cache/vllm-cache)
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] && env_args+=(-e "$key=$value")
  done < <(rsection env)
  env_args+=(
    -e "NCCL_SOCKET_IFNAME=$socket" -e "GLOO_SOCKET_IFNAME=$socket" -e "VLLM_HOST_IP=$ip"
    -e "NCCL_IB_HCA=$hca" -e "NCCL_IB_PEER_HCA=$peer" -e "NCCL_IB_GID_INDEX=$IB_GID_INDEX"
    -e NCCL_IB_DISABLE=0 -e "NCCL_NET=$NCCL_NET" -e "NCCL_NET_PLUGIN=$NCCL_NET_PLUGIN" -e "NCCL_ALGO=$NCCL_ALGO"
    -e "NCCL_P2P_DISABLE=$NCCL_P2P_DISABLE" -e "NCCL_SHM_DISABLE=$NCCL_SHM_DISABLE"
    -e NCCL_IGNORE_CPU_AFFINITY=1 -e "NCCL_CROSS_NIC=$NCCL_CROSS_NIC" -e "NCCL_IB_MERGE_NICS=$NCCL_IB_MERGE_NICS"
    -e "NCCL_IB_SUBNET_AWARE_ROUTING=$NCCL_IB_SUBNET_AWARE_ROUTING" -e "NCCL_IB_TIMEOUT=$NCCL_IB_TIMEOUT"
    -e "NCCL_IB_RETRY_CNT=$NCCL_IB_RETRY_CNT" -e "NCCL_IB_TOS=$NCCL_IB_TOS"
    -e "NCCL_MIN_NCHANNELS=$NCCL_MIN_NCHANNELS" -e "NCCL_MAX_NCHANNELS=$NCCL_MAX_NCHANNELS"
    -e "NCCL_BUFFSIZE=$NCCL_BUFFSIZE" -e "NCCL_SET_THREAD_NAME=$NCCL_SET_THREAD_NAME"
    -e "NCCL_TUNER_THRESHOLD=$NCCL_TUNER_THRESHOLD" -e "NCCL_CUMEM_HOST_ENABLE=$NCCL_CUMEM_HOST_ENABLE"
    -e "NCCL_DEBUG=$NCCL_DEBUG" -e "NCCL_DEBUG_SUBSYS=$NCCL_DEBUG_SUBSYS"
  )
  if [ "$USE_HOST_NCCL" = 1 ]; then
    env_args+=(-e "NCCL_HOST_DIR=$NCCL_CONTAINER_DIR" -e "LD_PRELOAD=$NCCL_PIN_CONTAINER $NCCL_CONTAINER_DIR/$NCCL_SO_NAME")
  fi
  command+=("${env_args[@]}" --entrypoint vllm "$IMAGE" serve "$CONTAINER_MODEL_PATH" --host "$API_HOST" --port "$PORT"
    --nnodes "$NNODES" --node-rank "$rank" --master-addr "$HEAD_IP" --master-port "$MASTER_PORT"
    --tensor-parallel-size "$TENSOR_PARALLEL_SIZE")
  [ "$rank" != 0 ] && command+=(--headless)
  command+=("${FLAGS[@]}")
  printf '%q ' "${command[@]}"
}

remove_rank_container() {
  local rank="$1" container
  container="$(rank_value "$rank" container)"
  if [ "$rank" = 0 ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  else
    worker_ssh_rank "$rank" "docker rm -f '$container' >/dev/null 2>&1 || true"
  fi
}

RANKS=(0 1)
[ "$NNODES" = 4 ] && RANKS+=(2 3)
mkdir -p "$CACHE_DIR"
for rank in "${RANKS[@]}"; do
  check_rank_assets "$rank"
  check_rank_fabric "$rank"
  if [ "$rank" = 0 ]; then
    mkdir -p "$(rank_cache_dir "$rank")"
  else
    worker_ssh_rank "$rank" "mkdir -p '$(rank_cache_dir "$rank")'"
  fi
  check_rank_image "$rank"
  remove_rank_container "$rank"
done
ok "Qwen TP${TENSOR_PARALLEL_SIZE} 模型、镜像和运行时资产已就绪（模型不复制）"

build_flags
info "启动 head rank=0，API=${API_HOST}:${PORT}，模型=${MODEL_ID}"
eval "$(compose_rank 0)" >/dev/null
sleep 2
for rank in "${RANKS[@]:1}"; do
  info "启动 worker rank=$rank"
  worker_ssh_rank "$rank" "$(compose_rank "$rank") >/dev/null"
done

CHECK_HOST="$API_HOST"
[ "$CHECK_HOST" = 0.0.0.0 ] && CHECK_HOST=127.0.0.1
for _ in $(seq 1 360); do
  if curl -sf -m 3 "http://${CHECK_HOST}:${PORT}/health" >/dev/null 2>&1; then
    ok "Qwen TP${TENSOR_PARALLEL_SIZE} 服务健康: http://${API_HOST}:${PORT}/v1"
    exit 0
  fi
  for rank in "${RANKS[@]}"; do
    container="$(rank_value "$rank" container)"
    if [ "$rank" = 0 ]; then
      if ! docker ps -q --filter "name=^${container}$" | grep -q .; then
        docker logs --tail 80 "$container" >&2 || true
        fail "rank $rank 容器已退出"
      fi
    elif ! worker_ssh_rank "$rank" "docker ps -q --filter 'name=^$container\$' | grep -q ." 2>/dev/null; then
      worker_ssh_rank "$rank" "docker logs --tail 80 '$container'" >&2 || true
      fail "rank $rank 容器已退出"
    fi
  done
  sleep 5
done
fail "服务在 30 分钟内未通过 /health；请查看 Qwen TP${TENSOR_PARALLEL_SIZE} 容器日志"
