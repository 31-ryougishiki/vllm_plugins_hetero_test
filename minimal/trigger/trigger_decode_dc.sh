#!/usr/bin/env bash
# minimal/trigger/trigger_decode_dc.sh
# 通过决策中心触发 decode 节点缩容：DP16TP1 -> DP15TP1。
# 任意节点执行：bash minimal/trigger/trigger_decode_dc.sh
set -euo pipefail

DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
FAULT_NODE_IP="${FAULT_NODE_IP:-${DECODE_HOST:-7.246.78.76}}"
FAULT_NPU="${FAULT_NPU:-15}"
FAULT_CODE="${FAULT_CODE:-80E78000}"

URL="${DECISION_CENTER_URL%/}/api/v1/decision_center/test/trigger_fault"
PAYLOAD="{\"node_ip\":\"${FAULT_NODE_IP}\",\"npu_id\":\"${FAULT_NPU}\",\"fault_code\":\"${FAULT_CODE}\"}"

echo "[trigger-d-dc] POST ${URL}"
echo "[trigger-d-dc] ${PAYLOAD}"

curl -fsS --max-time 60 -X POST "${URL}" \
    -H 'Content-Type: application/json' \
    -d "${PAYLOAD}"
echo
echo "[trigger-d-dc] OK"
