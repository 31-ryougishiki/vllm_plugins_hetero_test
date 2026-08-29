#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 场景 3（决策中心触发 RECOVER）：把场景 1/2 的降级拓扑恢复为对称。
#
# 前置：已执行场景 1 + 场景 2（P 异构、D DP15、proxy 已摘除 decoder15）。
# 本脚本在 prefill 节点执行，通过 /repair/devices 一次上报所有坏卡；
# 决策中心确认服务下无坏卡后自动下发 RECOVER。
#
# 使用方式（prefill 节点）：
#   nohup bash decision_center/run_scenario3_dc.sh \
#     > /opt/its/z30055003/logs/pd_scenario3_dc/run.log 2>&1 &
#
# RECOVER_TARGET=both|prefill|decode，含义与 run_scenario3.sh 相同。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_HETERO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFILL_HOST="${PREFILL_HOST:-7.246.78.75}"
DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
FAULT_NPU="${FAULT_NPU:-3}"
DECODE_FAULT_NPU="${DECODE_FAULT_NPU:-15}"

export TRIGGER_MODE=dc
export DECISION_CENTER_URL
export FAULT_NPU
export FAULT_NODE_IP="${PREFILL_HOST}"
export DECODE_HOST
export DECODE_FAULT_NPU
export RECOVER_TARGET="${RECOVER_TARGET:-both}"
export START_PREFILL="${START_PREFILL:-0}"
export START_PROXY="${START_PROXY:-0}"

echo "============================================================"
echo "[scenario3-dc] prefill recover: ${PREFILL_HOST}/${FAULT_NPU}"
echo "[scenario3-dc] decode recover : ${DECODE_HOST}/${DECODE_FAULT_NPU}"
echo "[scenario3-dc] recover target : ${RECOVER_TARGET}"
echo "[scenario3-dc] center         : ${DECISION_CENTER_URL}"
echo "============================================================"

bash "${PD_HETERO_DIR}/pd_hetero/run_scenario3.sh"
