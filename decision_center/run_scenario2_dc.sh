#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 场景 2（决策中心触发）：decode DP16TP1 -> DP15TP1，P 不变。
#
# 前置：P/D 已通过 decision_center/launch_*_dc.sh 拉起并注册到决策中心。
# 本脚本在 prefill 节点执行，通过决策中心 /test/trigger_fault 触发 D 节点
# NPU 15 故障；等待、摘除 decoder、预热和输出对比复用 run_scenario2.sh。
#
# 使用方式（prefill 节点）：
#   nohup bash decision_center/run_scenario2_dc.sh \
#     > /opt/its/z30055003/logs/pd_scenario2_dc/run.log 2>&1 &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_HETERO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
DECODE_FAULT_NPU="${DECODE_FAULT_NPU:-15}"

export TRIGGER_MODE=dc
export DECISION_CENTER_URL
export DECODE_HOST
export DECODE_FAULT_NPU
export START_PREFILL="${START_PREFILL:-1}"
export START_PROXY="${START_PROXY:-1}"

echo "============================================================"
echo "[scenario2-dc] decode   : ${DECODE_HOST}  (fault npu ${DECODE_FAULT_NPU})"
echo "[scenario2-dc] center   : ${DECISION_CENTER_URL}"
echo "============================================================"

bash "${PD_HETERO_DIR}/pd_hetero/run_scenario2.sh"
