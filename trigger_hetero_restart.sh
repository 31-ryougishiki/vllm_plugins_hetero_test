#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 手动触发 prefill DP4TP4 -> 异构 DP4TP(3,4,4,4) 重启。
#
# 默认模拟 NPU 3 故障（DP0 最后一张卡），向 4 个 executor 的 ITS HTTP 接口
# 下发完整 engine_parallel_config。四个 DP 会全部重启，最终：
#   global world_size = 15
#   DP0: npu 0,1,2   tp=3  tp_asymmetric_shardings=[2,1,1]
#   DP1: npu 4..7    tp=4
#   DP2: npu 8..11   tp=4
#   DP3: npu 12..15  tp=4
#
# 使用方式：
#   bash trigger_hetero_restart.sh
#   FAULT_NPU=0 bash trigger_hetero_restart.sh
#   DEPLOY_TYPE=DEGRADE bash trigger_hetero_restart.sh
#   SIMULATE_FAULT=false bash trigger_hetero_restart.sh
#
# 环境变量：
#   LOCAL_IP / ITS_HTTP_PORT_START / DP_SIZE / TP_SIZE / NUM_NPUS /
#   FAULT_NPU / SIMULATE_FAULT / DEPLOY_TYPE

set -euo pipefail

LOCAL_IP="${LOCAL_IP:-${VLLM_HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
NUM_NPUS="${NUM_NPUS:-16}"
FAULT_NPU="${FAULT_NPU:-3}"
SIMULATE_FAULT="${SIMULATE_FAULT:-true}"
DEPLOY_TYPE="${DEPLOY_TYPE:-PD_REBUILD}"

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi

echo "============================================================"
echo "[trigger] local ip     : ${LOCAL_IP}"
echo "[trigger] deploy type  : ${DEPLOY_TYPE}"
echo "[trigger] fault npu    : ${FAULT_NPU} (simulate=${SIMULATE_FAULT})"
echo "[trigger] target       : DP${DP_SIZE}TP(3,${TP_SIZE},${TP_SIZE},${TP_SIZE})"
echo "[trigger] ITS ports    : ${ITS_HTTP_PORT_START}..$((ITS_HTTP_PORT_START + (DP_SIZE - 1) * TP_SIZE))"
echo "============================================================"

python3 - "${LOCAL_IP}" "${FAULT_NPU}" "${SIMULATE_FAULT}" \
    "${DEPLOY_TYPE}" "${ITS_HTTP_PORT_START}" "${DP_SIZE}" "${TP_SIZE}" \
    "${NUM_NPUS}" <<'PY'
import json
import sys
import urllib.error
import urllib.request

(
    local_ip,
    fault_npu_raw,
    simulate_fault_raw,
    deploy_type,
    http_port_base,
    dp_size_raw,
    tp_size_raw,
    num_npus_raw,
) = sys.argv[1:9]

fault_npu = int(fault_npu_raw)
simulate_fault = simulate_fault_raw.lower() in ("1", "true", "yes")
http_port_base = int(http_port_base)
dp_size = int(dp_size_raw)
tp_size = int(tp_size_raw)
num_npus = int(num_npus_raw)

# 完整的 per-DP 异构拓扑；所有 executor 收到同一份列表，
# 顶层 executor_id 由下方循环设置为每个 DP 自身。
engine_parallel_config = [
    {
        "executor_id": "0",
        "dp": dp_size,
        "tp": tp_size,
        "data_parallel_rank": 0,
        "enable_expert_parallel": True,
        "new_dp": dp_size,
        "new_tp": 3,
        "tp_asymmetric_shardings": [2, 1, 1],
    }
]
for rank in range(1, dp_size):
    engine_parallel_config.append(
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
    )

devices = []
for npu_id in range(num_npus):
    devices.append(
        {
            "npu_id": npu_id,
            "device_ip": local_ip,
            "rank_id": str(npu_id),
            "npu_healthy": not (simulate_fault and npu_id == fault_npu),
        }
    )

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
    its_port = http_port_base + executor_id * tp_size
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
                f"[trigger] executor_id={executor_id} port={its_port} "
                f"HTTP {resp.status} -> {body}"
            )
    except (urllib.error.URLError, OSError) as exc:
        failed = True
        print(f"[trigger][ERROR] executor_id={executor_id} port={its_port} POST failed: {exc}")

if failed:
    print("[trigger] FAILED: at least one executor did not receive the strategy.")
    sys.exit(1)

print(
    "[trigger] all executors accepted the strategy. "
    "watch logs: grep -R 'restarting workers of EVERY DP instance' logs/prefill/"
)
PY
