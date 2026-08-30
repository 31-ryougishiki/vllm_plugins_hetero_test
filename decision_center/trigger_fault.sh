#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 通过决策中心测试接口触发一张 NPU 故障。
#
# 使用方式：
#   bash decision_center/trigger_fault.sh 7.246.78.75 3
#   或：
#   FAULT_NODE_IP=7.246.78.76 FAULT_NPU=15 bash decision_center/trigger_fault.sh
#
# 环境变量：
#   DECISION_CENTER_URL / FAULT_NODE_IP / FAULT_NPU / FAULT_CODE

set -euo pipefail

DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
FAULT_NODE_IP="${1:-${FAULT_NODE_IP:-}}"
FAULT_NPU="${2:-${FAULT_NPU:-}}"
FAULT_CODE="${FAULT_CODE:-80E78000}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ -z "${FAULT_NODE_IP}" || -z "${FAULT_NPU}" ]]; then
    echo "[trigger-fault][ERROR] usage: trigger_fault.sh <node_ip> <npu_id>" >&2
    exit 1
fi

echo "[trigger-fault] decision center: ${DECISION_CENTER_URL}"
echo "[trigger-fault] node/npu       : ${FAULT_NODE_IP}/${FAULT_NPU}"

"${PYTHON_BIN}" - "${DECISION_CENTER_URL}" "${FAULT_NODE_IP}" "${FAULT_NPU}" \
    "${FAULT_CODE}" <<'PY'
import json
import sys
import urllib.request

url, node_ip, npu_id, fault_code = sys.argv[1:5]
payload = {
    "node_ip": node_ip,
    "npu_id": str(npu_id),
    "fault_code": fault_code,
}
data = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(
    f"{url.rstrip('/')}/api/v1/decision_center/test/trigger_fault",
    data=data,
    headers={"Content-Type": "application/json"},
    method="POST",
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(req, timeout=60) as resp:
    body = resp.read().decode("utf-8", errors="replace")
print(f"HTTP {resp.status} -> {body}")
if resp.status != 200:
    sys.exit(1)
PY
