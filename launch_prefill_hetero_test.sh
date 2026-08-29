#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 单机拉起 prefill DP4TP4 服务（DeepSeek-V4-Flash-w8a8-mtp + MTP + PD kv_producer）
#
# 4 个 vllm serve 进程：
#   DP0: NPU 0-3   vllm port 9000  ITS http port 8001
#   DP1: NPU 4-7   vllm port 9001  ITS http port 8005
#   DP2: NPU 8-11  vllm port 9002  ITS http port 8009
#   DP3: NPU 12-15 vllm port 9003  ITS http port 8013
#
# 初始为对称 DP4TP4；异构 DP4TP(3,4,4,4) 由 trigger_hetero_restart.sh 下发。
#
# 使用方式：
#   nohup bash launch_prefill_hetero_test.sh > /opt/its/z30055003/logs/launch.log 2>&1 &
#
# 可覆盖的环境变量：
#   WORK_ROOT / MODEL_PATH / LOCAL_IP / NIC / DP_SIZE / TP_SIZE /
#   VLLM_PORT_START / DP_RPC_PORT / LOG_DIR

set -uo pipefail

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
VLLM_PORT_START="${VLLM_PORT_START:-9000}"
DP_RPC_PORT="${DP_RPC_PORT:-12345}"
LOG_DIR="${LOG_DIR:-${WORK_ROOT}/logs/prefill}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
# 必须使用安装 vllm_plugins 的同一个 Python 解释器启动服务；
# 不要依赖 PATH 里的 vllm serve，否则可能落到另一个 vllm 版本。
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi
if [[ ! -f "${MODEL_PATH}/config.json" ]]; then
    echo "[ERROR] model config not found: ${MODEL_PATH}/config.json" >&2
    echo "        set MODEL_PATH=/path/to/DeepSeek-V4-Flash-w8a8-mtp-self" >&2
    exit 1
fi
mkdir -p "${LOG_DIR}"

echo "============================================================"
echo "[launch] work root : ${WORK_ROOT}"
echo "[launch] model     : ${MODEL_PATH}"
echo "[launch] python    : ${PYTHON_BIN} -> $(command -v "${PYTHON_BIN}")"
echo "[launch] local ip  : ${LOCAL_IP}  nic: ${NIC}"
echo "[launch] topology  : DP${DP_SIZE}TP${TP_SIZE} (initial symmetric)"
echo "[launch] vllm ports: ${VLLM_PORT_START}..$((VLLM_PORT_START + DP_SIZE - 1))"
echo "[launch] ITS ports : ${ITS_HTTP_PORT_START}..$((ITS_HTTP_PORT_START + (DP_SIZE - 1) * TP_SIZE))"
echo "[launch] log dir   : ${LOG_DIR}"
echo "============================================================"

# ---------------- 网络 / NPU / Mooncake 公共环境 ----------------
export HCCL_IF_IP="${LOCAL_IP}"
export VLLM_HOST_IP="${LOCAL_IP}"
export GLOO_SOCKET_IFNAME="${NIC}"
export TP_SOCKET_IFNAME="${NIC}"
export HCCL_SOCKET_IFNAME="${NIC}"

# Mooncake/ADXL 建链与传输超时。
export ASCEND_CONNECT_TIMEOUT="${ASCEND_CONNECT_TIMEOUT:-180000}"
export ASCEND_TRANSFER_TIMEOUT="${ASCEND_TRANSFER_TIMEOUT:-300000}"
export MC_TRANSFER_TIMEOUT="${MC_TRANSFER_TIMEOUT:-600}"

# 大模型长超时。
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS="${VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS:-30000}"
export HCCL_EXEC_TIMEOUT="${HCCL_EXEC_TIMEOUT:-204}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-120}"
export VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-3600000}"

# CPU / 内存。
export OMP_PROC_BIND=false
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-10}"
export PYTORCH_NPU_ALLOC_CONF="${PYTORCH_NPU_ALLOC_CONF:-expandable_segments:True}"
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-2560}"
export TASK_QUEUE_ENABLE=1

# FlashComm1（DeepSeek-V4 DSA-CP 需要）。
export VLLM_ASCEND_ENABLE_FLASHCOMM1=1
export HCCL_OP_EXPANSION_MODE="AIV"

if [[ -f /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ]]; then
    export LD_PRELOAD="/usr/lib/aarch64-linux-gnu/libjemalloc.so.2:${LD_PRELOAD:-}"
fi

# ---------------- vllm_plugins / zero_interrupt ----------------
export VLLM_CUSTOM_PATCHES="${VLLM_CUSTOM_PATCHES:-zero_interrupt}"
# 纯脚本测试默认跳过 license 校验；生产环境务必去掉该变量并配置
# LICENSE_PATH / CERT_PATH / PRODUCT_KEY_PATH。
export VLLM_CUSTOM_PLUGINS_SKIP_LICENSE="${VLLM_CUSTOM_PLUGINS_SKIP_LICENSE:-1}"
export VLLM_ITS_HTTP_SERVER_PORT_START="${ITS_HTTP_PORT_START}"
export VLLM_ITS_ENABLE_FAULT_KEEP=true
export VLLM_ITS_ENABLE_PD_REBUILD=true
export VLLM_ITS_STRATEGY_TIMEOUT=600
export VLLM_ITS_HEALTH_CHECK_INTERVAL=5
# 纯脚本测试场景默认没有决策中心，避免 30s*3 次的上报重试拖慢启动。
# 有决策中心时在调用前覆盖：VLLM_ITS_DECISION_CENTER_URL=http://ip:port bash ...
export VLLM_ITS_DECISION_CENTER_URL="${VLLM_ITS_DECISION_CENTER_URL:-http://127.0.0.1:1}"
export VLLM_ITS_MAX_RETRY_COUNT="${VLLM_ITS_MAX_RETRY_COUNT:-1}"

launch_engine() {
    local dp_rank="$1"
    local visible_devices="$2"
    local vllm_port="$3"

    local log_file="${LOG_DIR}/dp${dp_rank}.log"
    # 决策中心要求同一服务的所有 executor 上报相同的 VLLM_SERVICE_ID。
    # 默认保留旧的手动测试行为；decision_center/ 启动脚本会显式传入。
    local service_id="${VLLM_SERVICE_ID:-hetero-test-dp4tp4-dp${dp_rank}}"

    echo "[launch] dp_rank=${dp_rank} devices=${visible_devices} port=${vllm_port} service_id=${service_id}"

    nohup env \
        ASCEND_RT_VISIBLE_DEVICES="${visible_devices}" \
        VLLM_SERVICE_ID="${service_id}" \
        "${PYTHON_BIN}" -m vllm.entrypoints.openai.api_server \
            --model "${MODEL_PATH}" \
            --host 0.0.0.0 \
            --port "${vllm_port}" \
            --data-parallel-size "${DP_SIZE}" \
            --data-parallel-rank "${dp_rank}" \
            --data-parallel-address "${LOCAL_IP}" \
            --data-parallel-rpc-port "${DP_RPC_PORT}" \
            --tensor-parallel-size "${TP_SIZE}" \
            --enable-expert-parallel \
            --seed 1024 \
            --served-model-name dsv4 \
            --max-model-len 1048576 \
            --max-num-batched-tokens 8192 \
            --max-num-seqs 16 \
            --no-disable-hybrid-kv-cache-manager \
            --model-loader-extra-config='{"enable_multithread_load": "true", "num_threads": 128}' \
            --no-enable-prefix-caching \
            --safetensors-load-strategy prefetch \
            --speculative-config '{"num_speculative_tokens": 1, "method": "mtp", "enforce_eager": true}' \
            --block-size 128 \
            --tokenizer-mode deepseek_v4 \
            --tool-call-parser deepseek_v4 \
            --enable-auto-tool-choice \
            --reasoning-parser deepseek_v4 \
            --gpu-memory-utilization 0.9 \
            --quantization ascend \
            --enforce-eager \
            --additional-config '{"enable_cpu_binding": true, "enable_shared_expert_dp": true, "enable_dsa_cp": true}' \
            --no-enable-eplb \
            --kv-transfer-config \
                '{"kv_connector": "MooncakeHybridConnector",
                  "kv_role": "kv_producer",
                  "kv_port": "36000",
                  "engine_id": "0",
                  "kv_connector_extra_config": {
                      "prefill": {"dp_size": 4, "tp_size": 4},
                      "decode": {"dp_size": 16, "tp_size": 1}
                  }}' \
            > "${log_file}" 2>&1 &
}

# 启动 4 个 DP engine。
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    device_start=$((dp_rank * TP_SIZE))
    visible_devices="$(
        seq -s ',' "${device_start}" $((device_start + TP_SIZE - 1))
    )"
    vllm_port=$((VLLM_PORT_START + dp_rank))
    launch_engine "${dp_rank}" "${visible_devices}" "${vllm_port}"
done

# 健康检查：用 Python urllib 并且显式禁用代理。
# 新节点常配置 http_proxy/http_proxy，curl 会对 127.0.0.1 也走代理导致 -sf 失败；
# 个别镜像又没有 curl。这里统一绕过代理，并避免依赖 curl 是否存在。
check_health() {
    local port="$1"
    python3 - "${port}" <<'PY'
import sys
import urllib.request

port = int(sys.argv[1])
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(f"http://127.0.0.1:{port}/health", timeout=5) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
}

echo "[launch] waiting for ${DP_SIZE} vllm engines ..."
READY=0
for attempt in $(seq 1 300); do
    READY=0
    for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
        vllm_port=$((VLLM_PORT_START + dp_rank))
        if check_health "${vllm_port}"; then
            READY=$((READY + 1))
        fi
    done
    if (( attempt == 1 || attempt % 10 == 0 || READY != 0 )); then
        echo "[launch] readiness attempt=${attempt}, ready=${READY}/${DP_SIZE}"
    fi
    if [[ "${READY}" -eq "${DP_SIZE}" ]]; then
        break
    fi
    sleep 2
done

if [[ "${READY}" -ne "${DP_SIZE}" ]]; then
    echo "[ERROR] only ${READY}/${DP_SIZE} vllm engines became ready in 600s." >&2
    echo "[ERROR] health probe: http://127.0.0.1:${VLLM_PORT_START}..$((VLLM_PORT_START + DP_SIZE - 1))/health" >&2
    echo "[ERROR] check logs under ${LOG_DIR}" >&2
    echo "[ERROR] proxy env: $(env | grep -i proxy || true)" >&2
    echo "[ERROR] listening ports:" >&2
    (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) >&2
    exit 1
fi

echo "[launch] all ${DP_SIZE} prefill engines are ready."
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    its_port=$((ITS_HTTP_PORT_START + dp_rank * TP_SIZE))
    echo "[launch] dp${dp_rank}: vllm http://127.0.0.1:$((VLLM_PORT_START + dp_rank))/health  ITS http://127.0.0.1:${its_port}/health"
done
echo "[launch] trigger heterogeneous restart: bash ${WORK_ROOT}/vllm_plugins_hetero_test/trigger_hetero_restart.sh"
