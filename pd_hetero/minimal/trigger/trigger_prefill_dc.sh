#!/usr/bin/env bash
# minimal/trigger/trigger_prefill_dc.sh
# 通过决策中心触发 prefill 节点缩容：DP4TP4 -> DP4TP(3,4,4,4)。
# 任意节点执行：bash minimal/trigger/trigger_prefill_dc.sh
set -euo pipefail

DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
FAULT_NODE_IP="${FAULT_NODE_IP:-${PREFILL_HOST:-7.246.78.74}}"
FAULT_NPU="${FAULT_NPU:-3}"
FAULT_CODE="${FAULT_CODE:-80E78000}"

URL="${DECISION_CENTER_URL%/}/api/v1/decision_center/test/trigger_fault"
PAYLOAD="{\"node_ip\":\"${FAULT_NODE_IP}\",\"npu_id\":\"${FAULT_NPU}\",\"fault_code\":\"${FAULT_CODE}\"}"

echo "[trigger-p-dc] POST ${URL}"
echo "[trigger-p-dc] ${PAYLOAD}"

curl -fsS --max-time 60 -X POST "${URL}" \
    -H 'Content-Type: application/json' \
    -d "${PAYLOAD}"
echo
echo "[trigger-p-dc] OK"
