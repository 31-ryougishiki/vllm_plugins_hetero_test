#!/usr/bin/env bash
# minimal/trigger/trigger_recover_dc.sh
# 通过决策中心上报坏卡修复，触发 RECOVER 扩容：
#   prefill: DP4TP(3,4,4,4) -> DP4TP4  （默认恢复 NPU 3）
#   decode : DP15TP1 -> DP16TP1        （默认恢复 NPU 15）
#
# 决策中心只在一次 /repair/devices 请求中确认服务下全部坏卡都已恢复时，
# 才会下发 RECOVER。因此：
#   - 只有一侧降级过：RECOVER_TARGET=prefill 或 decode
#   - P/D 两侧都降级过：必须 RECOVER_TARGET=both（默认），并一次上报两侧坏卡
#
# 使用方式（任意节点执行）：
#   bash minimal/trigger/trigger_recover_dc.sh                         # 两侧都恢复
#   RECOVER_TARGET=prefill bash minimal/trigger/trigger_recover_dc.sh
#   RECOVER_TARGET=decode  bash minimal/trigger/trigger_recover_dc.sh
#
# 环境变量：
#   DECISION_CENTER_URL / PREFILL_HOST / DECODE_HOST
#   FAULT_NPU / DECODE_FAULT_NPU / RECOVER_TARGET
set -euo pipefail

DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
PREFILL_HOST="${PREFILL_HOST:-7.246.78.74}"
DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
FAULT_NPU="${FAULT_NPU:-3}"
DECODE_FAULT_NPU="${DECODE_FAULT_NPU:-15}"
RECOVER_TARGET="${RECOVER_TARGET:-both}"

URL="${DECISION_CENTER_URL%/}/api/v1/decision_center/repair/devices"

case "${RECOVER_TARGET}" in
    prefill)
        PAYLOAD="[{\"node_ip\":\"${PREFILL_HOST}\",\"npu_id\":\"${FAULT_NPU}\"}]"
        ;;
    decode)
        PAYLOAD="[{\"node_ip\":\"${DECODE_HOST}\",\"npu_id\":\"${DECODE_FAULT_NPU}\"}]"
        ;;
    both)
        PAYLOAD="[{\"node_ip\":\"${PREFILL_HOST}\",\"npu_id\":\"${FAULT_NPU}\"},{\"node_ip\":\"${DECODE_HOST}\",\"npu_id\":\"${DECODE_FAULT_NPU}\"}]"
        ;;
    *)
        echo "[trigger-recover-dc][ERROR] invalid RECOVER_TARGET=${RECOVER_TARGET}, expected prefill|decode|both" >&2
        exit 1
        ;;
esac

echo "[trigger-recover-dc] POST ${URL}"
echo "[trigger-recover-dc] target=${RECOVER_TARGET}"
echo "[trigger-recover-dc] ${PAYLOAD}"

curl -fsS --max-time 60 -X POST "${URL}" \
    -H 'Content-Type: application/json' \
    -d "${PAYLOAD}"
echo
echo "[trigger-recover-dc] OK"
