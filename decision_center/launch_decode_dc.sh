#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 在 decode 节点（默认 7.246.78.76）拉起 DP16TP1，并注册到决策中心。
#
# P 和 D 必须使用同一个 VLLM_SERVICE_ID，决策中心才能把两个 engine 归到
# 一个服务里统一做故障寻优 / RECOVER。
#
# 使用方式（decode 节点执行）：
#   bash decision_center/launch_decode_dc.sh
#
# 环境变量：
#   DECODE_HOST / DECISION_CENTER_URL / VLLM_SERVICE_ID /
#   WORK_ROOT / MODEL_PATH / LOG_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
VLLM_SERVICE_ID="${VLLM_SERVICE_ID:-pd-hetero-service}"
WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOG_DIR="${LOG_DIR:-${WORK_ROOT}/logs/decode}"

export LOCAL_IP="${DECODE_HOST}"
export WORK_ROOT MODEL_PATH LOG_DIR
export VLLM_SERVICE_ID
export VLLM_ITS_DECISION_CENTER_URL="${DECISION_CENTER_URL}"
export VLLM_ITS_MAX_RETRY_COUNT="${VLLM_ITS_MAX_RETRY_COUNT:-3}"
# D 端依赖 deepseekv4/ 下的 patch_hetero_mooncake.py，运行期必须启用。
export VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"

echo "============================================================"
echo "[launch-d-dc] decode host       : ${DECODE_HOST}"
echo "[launch-d-dc] decision center   : ${DECISION_CENTER_URL}"
echo "[launch-d-dc] service id        : ${VLLM_SERVICE_ID}"
echo "[launch-d-dc] patch             : VLLM_ITS_DEEPSEEK_V4=${VLLM_ITS_DEEPSEEK_V4}"
echo "[launch-d-dc] topology          : DP16TP1"
echo "[launch-d-dc] log dir           : ${LOG_DIR}"
echo "============================================================"

bash "${ROOT_SCRIPT_DIR}/pd_hetero/decode/launch_decode_pd.sh"
