#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 在 prefill 节点（默认 7.246.78.75）拉起对称 DP4TP4，并注册到决策中心。
#
# 关键点：决策中心按 VLLM_SERVICE_ID 组织一个服务，P 的 4 个 executor
# 必须上报同一个 service_id；VLLM_ITS_DECISION_CENTER_URL 指向部署好的
# 决策中心。
#
# 使用方式（prefill 节点执行）：
#   bash decision_center/launch_prefill_dc.sh
#
# 环境变量：
#   PREFILL_HOST / DECISION_CENTER_URL / VLLM_SERVICE_ID /
#   WORK_ROOT / MODEL_PATH / LOG_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFILL_HOST="${PREFILL_HOST:-7.246.78.75}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
VLLM_SERVICE_ID="${VLLM_SERVICE_ID:-pd-hetero-service}"
WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOG_DIR="${LOG_DIR:-${WORK_ROOT}/logs/prefill}"

export LOCAL_IP="${PREFILL_HOST}"
export WORK_ROOT MODEL_PATH LOG_DIR
export VLLM_SERVICE_ID
export VLLM_ITS_DECISION_CENTER_URL="${DECISION_CENTER_URL}"
export VLLM_ITS_MAX_RETRY_COUNT="${VLLM_ITS_MAX_RETRY_COUNT:-3}"
# 合并后的 vllm_plugins 默认走 0829 runtime patch；决策中心场景同样
# 调试 DeepSeek-V4，运行期统一启用 deepseekv4 patch 族。
export VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"

echo "============================================================"
echo "[launch-p-dc] prefill host      : ${PREFILL_HOST}"
echo "[launch-p-dc] decision center   : ${DECISION_CENTER_URL}"
echo "[launch-p-dc] service id        : ${VLLM_SERVICE_ID}"
echo "[launch-p-dc] patch             : VLLM_ITS_DEEPSEEK_V4=${VLLM_ITS_DEEPSEEK_V4}"
echo "[launch-p-dc] topology          : DP4TP4 (symmetric)"
echo "[launch-p-dc] log dir           : ${LOG_DIR}"
echo "============================================================"

bash "${ROOT_SCRIPT_DIR}/launch_prefill_hetero_test.sh"
