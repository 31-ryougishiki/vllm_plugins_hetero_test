#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# decode 节点 start_server.sh：
#   注入 decode 环境变量 -> 用 launch_online_dp.py 按 DP 拉起 origin.sh。
#
# 使用方式（decode 节点）：
#   bash pd_hetero/decode/start_server.sh
# 后台运行：
#   nohup bash pd_hetero/decode/start_server.sh \
#     > /opt/its/z30055003/logs/decode/start_server.log 2>&1 &
#
# 默认配置：DP16TP1，vLLM 端口 9100..9115，注册到决策中心。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_HETERO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 必须从 pd_hetero 目录启动 launch_online_dp.py，它固定找 ./run_dp_template.sh。
cd "${PD_HETERO_DIR}"

# ---------------- 可覆盖参数 ----------------
DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
NIC="${NIC:-eth2}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
VLLM_SERVICE_ID="${VLLM_SERVICE_ID:-pd-hetero-service}"
DP_SIZE="${DP_SIZE:-16}"
TP_SIZE="${TP_SIZE:-1}"
VLLM_PORT_START="${VLLM_PORT_START:-9100}"
DP_RPC_PORT="${DP_RPC_PORT:-22345}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-18001}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
ENABLE_DETERMINISTIC="${ENABLE_DETERMINISTIC:-1}"

export LOCAL_IP="${DECODE_HOST}"
export DECODE_HOST NIC

# ---------------- 网络 / NPU / Mooncake 环境 ----------------
export HCCL_IF_IP="${LOCAL_IP}"
export VLLM_HOST_IP="${LOCAL_IP}"
export GLOO_SOCKET_IFNAME="${NIC}"
export TP_SOCKET_IFNAME="${NIC}"
export HCCL_SOCKET_IFNAME="${NIC}"
export ASCEND_CONNECT_TIMEOUT="${ASCEND_CONNECT_TIMEOUT:-180000}"
export ASCEND_TRANSFER_TIMEOUT="${ASCEND_TRANSFER_TIMEOUT:-300000}"
export MC_TRANSFER_TIMEOUT="${MC_TRANSFER_TIMEOUT:-600}"
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS="${VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS:-30000}"
export VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-3600000}"
export HCCL_EXEC_TIMEOUT="${HCCL_EXEC_TIMEOUT:-204}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-1200}"
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-1024}"
export HCCL_OP_EXPANSION_MODE="AIV"
export OMP_PROC_BIND=false
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-10}"
export PYTORCH_NPU_ALLOC_CONF="${PYTORCH_NPU_ALLOC_CONF:-expandable_segments:True}"
export TASK_QUEUE_ENABLE=1

# ---------------- vllm_plugins / 决策中心注册 ----------------
export VLLM_CUSTOM_PATCHES="${VLLM_CUSTOM_PATCHES:-zero_interrupt}"
export VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"
export VLLM_CUSTOM_PLUGINS_SKIP_LICENSE="${VLLM_CUSTOM_PLUGINS_SKIP_LICENSE:-1}"
export VLLM_SERVICE_ID
export VLLM_ITS_DECISION_CENTER_URL="${DECISION_CENTER_URL}"
export VLLM_ITS_MAX_RETRY_COUNT="${VLLM_ITS_MAX_RETRY_COUNT:-3}"
export VLLM_ITS_HTTP_SERVER_PORT_START="${ITS_HTTP_PORT_START}"
export VLLM_ITS_ENABLE_FAULT_KEEP=true
export VLLM_ITS_ENABLE_PD_REBUILD=true
export VLLM_ITS_STRATEGY_TIMEOUT=600
export VLLM_ITS_HEALTH_CHECK_INTERVAL=5

# ---------------- 确定性开关（默认开启） ----------------
if [[ "${ENABLE_DETERMINISTIC}" == "1" ]]; then
    export HCCL_DETERMINISTIC="${HCCL_DETERMINISTIC:-true}"
    export LCCL_DETERMINISTIC="${LCCL_DETERMINISTIC:-1}"
    export ATB_MATMUL_SHUFFLE_K_ENABLE="${ATB_MATMUL_SHUFFLE_K_ENABLE:-0}"
    export ATB_LLM_LCOC_ENABLE="${ATB_LLM_LCOC_ENABLE:-0}"
fi

# ---------------- 交给 launch_online_dp.py 按 DP 拉起 ----------------
export NODE_ROLE=decode
export ORIGIN_SCRIPT="${SCRIPT_DIR}/origin.sh"

echo "============================================================"
echo "[start-server-d] host     : ${DECODE_HOST}"
echo "[start-server-d] topology : DP${DP_SIZE}TP${TP_SIZE}"
echo "[start-server-d] ports    : ${VLLM_PORT_START}..$((VLLM_PORT_START + DP_SIZE - 1))"
echo "[start-server-d] dc       : ${DECISION_CENTER_URL}"
echo "[start-server-d] service  : ${VLLM_SERVICE_ID}"
echo "[start-server-d] origin   : ${ORIGIN_SCRIPT}"
echo "[start-server-d] determin : ${ENABLE_DETERMINISTIC}"
echo "============================================================"

exec "${PYTHON_BIN}" "${PD_HETERO_DIR}/launch_online_dp.py" \
    --dp-size "${DP_SIZE}" \
    --tp-size "${TP_SIZE}" \
    --dp-size-local "${DP_SIZE}" \
    --dp-address "${LOCAL_IP}" \
    --dp-rpc-port "${DP_RPC_PORT}" \
    --vllm-start-port "${VLLM_PORT_START}"
