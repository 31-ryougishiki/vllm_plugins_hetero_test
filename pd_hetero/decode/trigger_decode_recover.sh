#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 3：decode 节点恢复，DP15TP1 -> DP16TP1。
#
# 在 D 节点本地执行。假设场景 2 已经把 executor 15 缩到零、其余 15 个
# executor 运行在 DP15TP1。本脚本向全部 16 个 decode executor 下发
# RECOVER 策略：
#   - executor 0..14: DP15 -> DP16，TP1 保持不变；
#   - executor 15: 从 Idle mode 恢复为 1 个 worker，重新加入 16-rank 全局
#     通信域和 EngineCore dp_group。
#
# 使用方式（decode 节点执行）：
#   bash decode/trigger_decode_recover.sh
#
# 环境变量：
#   LOCAL_IP / DECODE_DP_SIZE / DECODE_TP_SIZE / NUM_NPUS /
#   DECODE_FAULT_NPU / DECODE_ITS_PORT_START / DECODE_VLLM_PORT_START /
#   DECODE_LOG_DIR / RESTART_TIMEOUT

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
DECODE_TP_SIZE="${DECODE_TP_SIZE:-1}"
NUM_NPUS="${NUM_NPUS:-16}"
DECODE_FAULT_NPU="${DECODE_FAULT_NPU:-15}"
DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START:-18001}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_LOG_DIR="${DECODE_LOG_DIR:-/opt/its/z30055003/logs/decode}"
DEPLOY_TYPE="${DEPLOY_TYPE:-RECOVER}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[trigger-decode-recover][ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi
if (( DECODE_FAULT_NPU < 0 || DECODE_FAULT_NPU >= NUM_NPUS )); then
    echo "[trigger-decode-recover][ERROR] DECODE_FAULT_NPU=${DECODE_FAULT_NPU} must be in [0, ${NUM_NPUS})" >&2
    exit 1
fi

echo "============================================================"
echo "[trigger-decode-recover] local ip       : ${LOCAL_IP}"
echo "[trigger-decode-recover] deploy type    : ${DEPLOY_TYPE}"
echo "[trigger-decode-recover] recovered npu  : ${DECODE_FAULT_NPU}"
echo "[trigger-decode-recover] target         : DP${DECODE_DP_SIZE}TP${DECODE_TP_SIZE}"
echo "[trigger-decode-recover] ITS ports      : ${DECODE_ITS_PORT_START}..$((DECODE_ITS_PORT_START + DECODE_DP_SIZE - 1))"
echo "[trigger-decode-recover] log dir        : ${DECODE_LOG_DIR}"
echo "============================================================"

"${PYTHON_BIN}" - "${LOCAL_IP}" "${DECODE_FAULT_NPU}" "${DEPLOY_TYPE}" \
    "${DECODE_ITS_PORT_START}" "${DECODE_DP_SIZE}" "${DECODE_TP_SIZE}" \
    "${NUM_NPUS}" <<'PY'
import json
import sys
import urllib.error
import urllib.request

(
    local_ip,
    recovered_npu_raw,
    deploy_type,
    its_port_base,
    dp_size_raw,
    tp_size_raw,
    num_npus_raw,
) = sys.argv[1:9]

recovered_npu = int(recovered_npu_raw)
its_port_base = int(its_port_base)
dp_size = int(dp_size_raw)
tp_size = int(tp_size_raw)
num_npus = int(num_npus_raw)

# RECOVER 的 conf.dp/tp/data_parallel_rank 是第一次 DEGRADE 前备份的
# 对称值；new_dp/new_tp 是恢复后的目标值。
engine_parallel_config = [
    {
        "executor_id": str(rank),
        "dp": dp_size,
        "tp": tp_size,
        "data_parallel_rank": rank,
        "enable_expert_parallel": True,
        "new_dp": dp_size,
        "new_tp": tp_size,
        "tp_asymmetric_shardings": None,
    }
    for rank in range(dp_size)
]

devices = [
    {
        "npu_id": npu_id,
        "device_ip": local_ip,
        "rank_id": str(npu_id),
        "npu_healthy": True,
    }
    for npu_id in range(num_npus)
]

npu_healthy_state = [
    {
        "server_count": "1",
        "status": "completed",
        "version": "1.0",
        "server_list": [
            {
                "server_id": "server-1",
                "host_ip": local_ip,
                "device": devices,
            }
        ],
    }
]

failed = False
for executor_id in range(dp_size):
    its_port = its_port_base + executor_id
    payload = {
        "deploy_type": deploy_type,
        "executor_id": str(executor_id),
        "engine_parallel_config": engine_parallel_config,
        "engine_npu_healthy_state": npu_healthy_state,
    }
    data = json.dumps(payload).encode("utf-8")
    url = f"http://127.0.0.1:{its_port}/api/v1/executor/deploy"
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            print(
                f"[trigger-decode-recover] executor_id={executor_id} "
                f"port={its_port} HTTP {resp.status} -> {body}"
            )
    except (urllib.error.URLError, OSError) as exc:
        failed = True
        print(
            f"[trigger-decode-recover][ERROR] executor_id={executor_id} "
            f"port={its_port} POST failed: {exc}"
        )

if failed:
    print("[trigger-decode-recover] FAILED: at least one decode executor did not accept the strategy.")
    sys.exit(1)

print("[trigger-decode-recover] all decode executors accepted the strategy.")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    exit ${RC}
fi

wait_log_marker() {
    local log_file="$1"
    local marker="$2"
    for _attempt in $(seq 1 $((RESTART_TIMEOUT / 2))); do
        if grep -q "${marker}" "${log_file}" 2>/dev/null; then
            echo "[trigger-decode-recover] found '${marker}' in ${log_file}"
            return 0
        fi
        sleep 2
    done
    echo "[trigger-decode-recover][ERROR] timeout waiting for '${marker}' in ${log_file}" >&2
    return 1
}

echo "[trigger-decode-recover] waiting for full-restart barrier and restart markers ..."
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    log_file="${DECODE_LOG_DIR}/dp${rank}.log"
    wait_log_marker "${log_file}" "restarting workers of EVERY DP instance" || exit 1
    wait_log_marker "${log_file}" "Full-restart barrier passed" || exit 1
done

echo "[trigger-decode-recover] waiting for all ${DECODE_DP_SIZE} decode engines ..."
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    port=$((DECODE_VLLM_PORT_START + rank))
    ready=0
    for _attempt in $(seq 1 $((RESTART_TIMEOUT / 2))); do
        if "${PYTHON_BIN}" - "${port}" <<'PY'
import sys
import urllib.request

port = int(sys.argv[1])
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(f"http://127.0.0.1:{port}/health", timeout=5) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
        then
            ready=1
            break
        fi
        sleep 2
    done
    if [[ "${ready}" -ne 1 ]]; then
        echo "[trigger-decode-recover][ERROR] decode engine rank=${rank} port=${port} did not become healthy" >&2
        exit 1
    fi
done

echo "[trigger-decode-recover] decode DP${DECODE_DP_SIZE}TP${DECODE_TP_SIZE} recovery completed."
echo "[trigger-decode-recover] executor ${DECODE_FAULT_NPU} has rejoined the decode engine group."
