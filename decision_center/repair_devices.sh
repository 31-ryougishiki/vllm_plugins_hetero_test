#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 通过决策中心上报坏卡修复。决策中心会在“一个服务下所有坏卡都上报修复”
# 之后自动下发 RECOVER。
#
# 使用方式（node_ip:npu_id，可一次传多张卡）：
#   bash decision_center/repair_devices.sh 7.246.78.75:3
#   bash decision_center/repair_devices.sh 7.246.78.75:3 7.246.78.76:15
#   或：
#   REPAIR_PAIRS="7.246.78.75:3,7.246.78.76:15" bash decision_center/repair_devices.sh
#
# 环境变量：
#   DECISION_CENTER_URL / REPAIR_PAIRS（逗号分隔 node_ip:npu_id）

set -euo pipefail

DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
if [[ $# -gt 0 ]]; then
    REPAIR_PAIRS="$(IFS=,; echo "$*")"
else
    REPAIR_PAIRS="${REPAIR_PAIRS:-}"
fi

if [[ -z "${REPAIR_PAIRS}" ]]; then
    echo "[repair-devices][ERROR] no repair pairs given. usage: repair_devices.sh <node_ip>:<npu_id> ..." >&2
    exit 1
fi

echo "[repair-devices] decision center: ${DECISION_CENTER_URL}"
echo "[repair-devices] pairs          : ${REPAIR_PAIRS}"

"${PYTHON_BIN}" - "${DECISION_CENTER_URL}" "${REPAIR_PAIRS}" <<'PY'
import json
import sys
import urllib.request

url, pairs_raw = sys.argv[1], sys.argv[2]
payload = []
for pair in pairs_raw.split(","):
    pair = pair.strip()
    if not pair:
        continue
    node_ip, npu_id = pair.rsplit(":", 1)
    payload.append({"node_ip": node_ip, "npu_id": str(npu_id)})

data = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(
    f"{url.rstrip('/')}/api/v1/decision_center/repair/devices",
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
