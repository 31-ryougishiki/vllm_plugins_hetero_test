#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 1 的 D 端（decode，保持不变）。
#
# 在独立的 decode 节点上拉起 dp16/tp1 的 kv_consumer。该节点不接收任何
# 异构重启策略，始终以 DP16TP1 运行；prefill 节点异构重启后，D 端通过
# vllm_plugins 的 MooncakeHybridConnector patch 按新 engine_id / handshake_port
# 重新恢复 KV 传输链。
#
# 参考实现：hetero_cp/run_script_hetero/decode/*
#
# 使用方式（在 decode 节点执行）：
#   nohup bash launch_decode_pd.sh > /opt/its/z30055003/logs/decode/launch.log 2>&1 &
#
# 前置条件：
#   - decode 节点已安装 vllm + vllm_ascend v0.23.0，且已安装 vllm_plugins
#     （bash vllm_plugins_hetero_test/install_vllm_plugins.sh）；
#   - 16 张可用 NPU（脚本默认按 dp_rank 顺序使用 NPU 0..15）。
#
# 可覆盖的环境变量：
#   WORK_ROOT / MODEL_PATH / LOCAL_IP / NIC /
#   DECODE_DP_SIZE / DECODE_TP_SIZE / DECODE_VLLM_PORT_START /
#   DECODE_DP_RPC_PORT / DECODE_KV_PORT / DECODE_ENGINE_ID / DECODE_ITS_PORT_START /
#   DECODE_DEVICE_START / LOG_DIR / PYTHON_BIN

set -uo pipefail

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
DECODE_TP_SIZE="${DECODE_TP_SIZE:-1}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_DP_RPC_PORT="${DECODE_DP_RPC_PORT:-22345}"
DECODE_KV_PORT="${DECODE_KV_PORT:-36200}"
DECODE_ENGINE_ID="${DECODE_ENGINE_ID:-1}"
DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START:-18001}"
DECODE_DEVICE_START="${DECODE_DEVICE_START:-0}"
LOG_DIR="${LOG_DIR:-${WORK_ROOT}/logs/decode}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[decode][ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi
if [[ ! -f "${MODEL_PATH}/config.json" ]]; then
    echo "[decode][ERROR] model config not found: ${MODEL_PATH}/config.json" >&2
    echo "              set MODEL_PATH=/path/to/DeepSeek-V4-Flash-w8a8-mtp-self" >&2
    exit 1
fi
mkdir -p "${LOG_DIR}"

echo "============================================================"
echo "[decode] work root : ${WORK_ROOT}"
echo "[decode] model     : ${MODEL_PATH}"
echo "[decode] python    : ${PYTHON_BIN} -> $(command -v "${PYTHON_BIN}")"
echo "[decode] local ip  : ${LOCAL_IP}  nic: ${NIC}"
echo "[decode] topology  : DP${DECODE_DP_SIZE}TP${DECODE_TP_SIZE} (unchanged)"
echo "[decode] vllm ports: ${DECODE_VLLM_PORT_START}..$((DECODE_VLLM_PORT_START + DECODE_DP_SIZE - 1))"
echo "[decode] ITS ports : ${DECODE_ITS_PORT_START}..$((DECODE_ITS_PORT_START + DECODE_DP_SIZE - 1))"
echo "[decode] patch     : VLLM_ITS_DEEPSEEK_V4=${VLLM_ITS_DEEPSEEK_V4:-1} (1=DeepSeek-V4)"
echo "[decode] kv role   : kv_consumer, kv_port=${DECODE_KV_PORT}, engine_id=${DECODE_ENGINE_ID}"
echo "[decode] log dir   : ${LOG_DIR}"
echo "============================================================"

# ---------------- 网络 / NPU / Mooncake 公共环境 ----------------
export HCCL_IF_IP="${LOCAL_IP}"
export VLLM_HOST_IP="${LOCAL_IP}"
export GLOO_SOCKET_IFNAME="${NIC}"
export TP_SOCKET_IFNAME="${NIC}"
export HCCL_SOCKET_IFNAME="${NIC}"

export ASCEND_CONNECT_TIMEOUT="${ASCEND_CONNECT_TIMEOUT:-180000}"
export ASCEND_TRANSFER_TIMEOUT="${ASCEND_TRANSFER_TIMEOUT:-300000}"
export MC_TRANSFER_TIMEOUT="${MC_TRANSFER_TIMEOUT:-600}"

export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS="${VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS:-30000}"
export HCCL_EXEC_TIMEOUT="${HCCL_EXEC_TIMEOUT:-204}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-1200}"
export VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-3600000}"

export OMP_PROC_BIND=false
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-10}"
export PYTORCH_NPU_ALLOC_CONF="${PYTORCH_NPU_ALLOC_CONF:-expandable_segments:True}"
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-1024}"
export TASK_QUEUE_ENABLE=1
export HCCL_OP_EXPANSION_MODE="AIV"

if [[ -f /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ]]; then
    export LD_PRELOAD="/usr/lib/aarch64-linux-gnu/libjemalloc.so.2:${LD_PRELOAD:-}"
fi

# ---------------- vllm_plugins / zero_interrupt ----------------
# D 端不触发策略，但必须加载 zero_interrupt，否则 MooncakeHybridConnector
# 的异构 engine_id/端口恢复 patch 不会生效。
export VLLM_CUSTOM_PATCHES="${VLLM_CUSTOM_PATCHES:-zero_interrupt}"
# patch_hetero_mooncake.py 位于合并后的 deepseekv4/ 目录，因此 D 端
# 运行期也必须使用 DeepSeek-V4 patch 族。
export VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"
export VLLM_CUSTOM_PLUGINS_SKIP_LICENSE="${VLLM_CUSTOM_PLUGINS_SKIP_LICENSE:-1}"
export VLLM_ITS_HTTP_SERVER_PORT_START="${DECODE_ITS_PORT_START}"
export VLLM_ITS_ENABLE_FAULT_KEEP=true
export VLLM_ITS_ENABLE_PD_REBUILD=true
export VLLM_ITS_STRATEGY_TIMEOUT=600
export VLLM_ITS_HEALTH_CHECK_INTERVAL=5
# D 端没有决策中心/策略下发，避免上报重试拖慢启动。
export VLLM_ITS_DECISION_CENTER_URL="${VLLM_ITS_DECISION_CENTER_URL:-http://127.0.0.1:1}"
export VLLM_ITS_MAX_RETRY_COUNT="${VLLM_ITS_MAX_RETRY_COUNT:-1}"

launch_engine() {
    local dp_rank="$1"
    local visible_devices="$2"
    local vllm_port="$3"

    local log_file="${LOG_DIR}/dp${dp_rank}.log"
    # 决策中心要求同一服务的所有 executor 上报相同的 VLLM_SERVICE_ID。
    # 默认保留旧的手动测试行为；decision_center/ 启动脚本会显式传入。
    local service_id="${VLLM_SERVICE_ID:-pd-hetero-decode-dp${dp_rank}}"
    echo "[decode] dp_rank=${dp_rank} device=${visible_devices} port=${vllm_port} service_id=${service_id}"

    nohup env \
        ASCEND_RT_VISIBLE_DEVICES="${visible_devices}" \
        VLLM_SERVICE_ID="${service_id}" \
        "${PYTHON_BIN}" -m vllm.entrypoints.openai.api_server \
            --model "${MODEL_PATH}" \
            --host 0.0.0.0 \
            --port "${vllm_port}" \
            --data-parallel-size "${DECODE_DP_SIZE}" \
            --data-parallel-rank "${dp_rank}" \
            --data-parallel-address "${LOCAL_IP}" \
            --data-parallel-rpc-port "${DECODE_DP_RPC_PORT}" \
            --tensor-parallel-size "${DECODE_TP_SIZE}" \
            --enable-expert-parallel \
            --seed 1024 \
            --served-model-name dsv4 \
            --max-model-len 1048576 \
            --max-num-batched-tokens 120 \
            --max-num-seqs 60 \
            --async-scheduling \
            --block-size 128 \
            --no-disable-hybrid-kv-cache-manager \
            --no-enable-prefix-caching \
            --safetensors-load-strategy prefetch \
            --trust-remote-code \
            --tokenizer-mode deepseek_v4 \
            --model-loader-extra-config='{"enable_multithread_load": "true", "num_threads": 128}' \
            --tool-call-parser deepseek_v4 \
            --enable-auto-tool-choice \
            --reasoning-parser deepseek_v4 \
            --gpu-memory-utilization 0.9 \
            --quantization ascend \
            --speculative-config '{"num_speculative_tokens": 1, "method": "mtp", "enforce_eager": true}' \
            --compilation-config '{"cudagraph_mode": "FULL_DECODE_ONLY"}' \
            --kv-transfer-config \
                '{"kv_connector": "MooncakeHybridConnector",
                  "kv_role": "kv_consumer",
                  "kv_port": "'"${DECODE_KV_PORT}"'",
                  "engine_id": "'"${DECODE_ENGINE_ID}"'",
                  "kv_connector_extra_config": {
                      "prefill": {"dp_size": 4, "tp_size": 4},
                      "decode": {"dp_size": '"${DECODE_DP_SIZE}"', "tp_size": '"${DECODE_TP_SIZE}"'}
                  }}' \
            --additional-config '{
                "ascend_compilation_config": {
                    "enable_npugraph_ex": true,
                    "enable_static_kernel": false
                },
                "enable_cpu_binding": true,
                "multistream_overlap_shared_expert": true,
                "recompute_scheduler_enable": true
            }' \
            > "${log_file}" 2>&1 &
}

for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    device_id=$((DECODE_DEVICE_START + dp_rank))
    vllm_port=$((DECODE_VLLM_PORT_START + dp_rank))
    launch_engine "${dp_rank}" "${device_id}" "${vllm_port}"
done

# 健康检查：显式绕过代理，避免节点 http_proxy 配置影响本地探测。
check_health() {
    local port="$1"
    "${PYTHON_BIN}" - "${port}" <<'PY'
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

echo "[decode] waiting for ${DECODE_DP_SIZE} decode engines ..."
READY=0
for attempt in $(seq 1 450); do
    READY=0
    for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
        vllm_port=$((DECODE_VLLM_PORT_START + dp_rank))
        if check_health "${vllm_port}"; then
            READY=$((READY + 1))
        fi
    done
    if (( attempt == 1 || attempt % 10 == 0 || READY != 0 )); then
        echo "[decode] readiness attempt=${attempt}, ready=${READY}/${DECODE_DP_SIZE}"
    fi
    if [[ "${READY}" -eq "${DECODE_DP_SIZE}" ]]; then
        break
    fi
    sleep 2
done

if [[ "${READY}" -ne "${DECODE_DP_SIZE}" ]]; then
    echo "[decode][ERROR] only ${READY}/${DECODE_DP_SIZE} engines became ready." >&2
    echo "[decode][ERROR] check logs under ${LOG_DIR}" >&2
    exit 1
fi

echo "[decode] all ${DECODE_DP_SIZE} decode engines are ready and unchanged."
echo "[decode] prefill can now run: bash vllm_plugins_hetero_test/pd_hetero/run_scenario1.sh"
