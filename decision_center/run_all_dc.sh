#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 决策中心全流程：场景1 -> 场景2 -> 场景3。
#
# 前置：P/D 已通过 decision_center/launch_*_dc.sh 拉起。
# 场景1 会启动代理并完成基线；场景2 复用；场景3 恢复。
#
# 使用方式（prefill 节点）：
#   DECODE_HOST=7.246.78.76 \
#   nohup bash decision_center/run_all_dc.sh \
#     > /opt/its/z30055003/logs/decision_center_all.log 2>&1 &

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DECODE_HOST="${DECODE_HOST:-7.246.78.76}"

echo "[dc-all] ============ scenario 1 (P hetero degrade) ============"
DECODE_HOST="${DECODE_HOST}" bash "${SCRIPT_DIR}/run_scenario1_dc.sh"

echo "[dc-all] ============ scenario 2 (D DP16 -> DP15) ============"
DECODE_HOST="${DECODE_HOST}" START_PREFILL=0 START_PROXY=0 \
    bash "${SCRIPT_DIR}/run_scenario2_dc.sh"

echo "[dc-all] ============ scenario 3 (RECOVER both) ============"
DECODE_HOST="${DECODE_HOST}" bash "${SCRIPT_DIR}/run_scenario3_dc.sh"

echo "[dc-all] PASS: scenario1 -> scenario2 -> scenario3 completed via decision center"
