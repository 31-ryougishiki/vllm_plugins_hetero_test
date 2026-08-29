#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 场景 1（决策中心触发）：prefill DP4TP4 -> DP4TP(3,4,4,4)，D 不变。
#
# 前置：P 节点已执行 launch_prefill_dc.sh、D 节点已执行 launch_decode_dc.sh。
# 本脚本在 prefill 节点执行，通过决策中心 /test/trigger_fault 触发 NPU 3 故障，
# 后续等待、代理预热和输出对比复用 pd_hetero/run_scenario1.sh。
#
# 使用方式（prefill 节点）：
#   DECODE_HOST=7.246.78.76 nohup bash decision_center/run_scenario1_dc.sh \
#     > /opt/its/z30055003/logs/pd_scenario1_dc/run.log 2>&1 &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_HETERO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFILL_HOST="${PREFILL_HOST:-7.246.78.75}"
DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
FAULT_NPU="${FAULT_NPU:-3}"

export TRIGGER_MODE=dc
export DECISION_CENTER_URL
export FAULT_NPU
export FAULT_NODE_IP="${PREFILL_HOST}"
export DECODE_HOST
export START_PREFILL="${START_PREFILL:-1}"
export START_PROXY="${START_PROXY:-1}"

echo "============================================================"
echo "[scenario1-dc] prefill  : ${PREFILL_HOST}  (fault npu ${FAULT_NPU})"
echo "[scenario1-dc] decode   : ${DECODE_HOST}  (unchanged)"
echo "[scenario1-dc] center   : ${DECISION_CENTER_URL}"
echo "============================================================"

bash "${PD_HETERO_DIR}/pd_hetero/run_scenario1.sh"
