#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 1 的负载均衡代理。
#
# 在 prefill 节点上启动，负责：
#   1. 先向某个 prefill engine 发 max_tokens=1 请求；
#   2. 拿到 kv_transfer_params 后把续推请求转发到 decode engine。
#
# 参考实现：hetero_cp/run_script_hetero/proxy.sh 与
#          load_balance_proxy_server_example.py（本目录为原样拷贝）。
#
# 使用方式（prefill 节点执行）：
#   nohup bash start_proxy_pd.sh > /opt/its/z30055003/logs/pd_scenario1/proxy.log 2>&1 &
#
# 可覆盖的环境变量：
#   PROXY_HOST / PROXY_PORT /
#   PREFILL_HOST / PREFILL_VLLM_PORT_START / PREFILL_DP_SIZE /
#   DECODE_HOST / DECODE_VLLM_PORT_START / DECODE_DP_SIZE /
#   PYTHON_BIN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXY_HOST="${PROXY_HOST:-0.0.0.0}"
PROXY_PORT="${PROXY_PORT:-8000}"
PREFILL_HOST="${PREFILL_HOST:-127.0.0.1}"
PREFILL_VLLM_PORT_START="${PREFILL_VLLM_PORT_START:-9000}"
PREFILL_DP_SIZE="${PREFILL_DP_SIZE:-4}"
DECODE_HOST="${DECODE_HOST:?export DECODE_HOST=<decode-node-ip>}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

PREFILL_PORTS=()
for ((i = 0; i < PREFILL_DP_SIZE; i++)); do
    PREFILL_PORTS+=("$((PREFILL_VLLM_PORT_START + i))")
done
DECODE_PORTS=()
for ((i = 0; i < DECODE_DP_SIZE; i++)); do
    DECODE_PORTS+=("$((DECODE_VLLM_PORT_START + i))")
done

PREFILL_HOSTS=()
DECODE_HOSTS=()
for ((i = 0; i < PREFILL_DP_SIZE; i++)); do
    PREFILL_HOSTS+=("${PREFILL_HOST}")
done
for ((i = 0; i < DECODE_DP_SIZE; i++)); do
    DECODE_HOSTS+=("${DECODE_HOST}")
done

echo "============================================================"
echo "[proxy] listen      : ${PROXY_HOST}:${PROXY_PORT}"
echo "[proxy] prefills    : ${PREFILL_HOST}:${PREFILL_PORTS[*]}"
echo "[proxy] decodes     : ${DECODE_HOST}:${DECODE_PORTS[*]}"
echo "============================================================"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/load_balance_proxy_server.py" \
    --host "${PROXY_HOST}" \
    --port "${PROXY_PORT}" \
    --prefiller-hosts "${PREFILL_HOSTS[@]}" \
    --prefiller-ports "${PREFILL_PORTS[@]}" \
    --decoder-hosts "${DECODE_HOSTS[@]}" \
    --decoder-ports "${DECODE_PORTS[@]}"
