#!/usr/bin/env bash
# minimal/decode: 注入决策中心变量，用 launch_online_dp.py 拉起 DP16TP1。
set -euo pipefail

cd "$(dirname "$0")"

export LOCAL_IP="${LOCAL_IP:-7.246.78.76}"
export VLLM_ITS_DECISION_CENTER_URL="${VLLM_ITS_DECISION_CENTER_URL:-http://7.246.78.79:8088}"
export VLLM_SERVICE_ID="${VLLM_SERVICE_ID:-pd-hetero-service}"
export VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"
export VLLM_CUSTOM_PATCHES="${VLLM_CUSTOM_PATCHES:-zero_interrupt}"
export VLLM_ITS_MAX_RETRY_COUNT=3
export VLLM_ITS_ENABLE_FAULT_KEEP=true
export VLLM_ITS_ENABLE_PD_REBUILD=true
export VLLM_ITS_HTTP_SERVER_PORT_START=18001
export HCCL_DETERMINISTIC=true LCCL_DETERMINISTIC=1 \
       ATB_MATMUL_SHUFFLE_K_ENABLE=0 ATB_LLM_LCOC_ENABLE=0

exec python3 launch_online_dp.py \
    --dp-size 16 \
    --tp-size 1 \
    --dp-size-local 16 \
    --dp-address "${LOCAL_IP}" \
    --dp-rpc-port 22345 \
    --vllm-start-port 9100
