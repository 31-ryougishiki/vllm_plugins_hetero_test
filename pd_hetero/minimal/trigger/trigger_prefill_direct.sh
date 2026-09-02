#!/usr/bin/env bash
# minimal/trigger/trigger_prefill_direct.sh
# 直接向本机 4 个 prefill executor 下发缩容策略：DP4TP4 -> DP4TP(3,4,4,4)。
# 在 prefill 节点执行：bash minimal/trigger/trigger_prefill_direct.sh
set -euo pipefail

LOCAL_IP="${LOCAL_IP:-7.246.78.75}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
NUM_NPUS="${NUM_NPUS:-16}"
FAULT_NPU="${FAULT_NPU:-3}"
DEPLOY_TYPE="${DEPLOY_TYPE:-PD_REBUILD}"

echo "[trigger-p-direct] ${LOCAL_IP} DP${DP_SIZE}TP${TP_SIZE} -> DP${DP_SIZE}TP(3,4,4,4), fault npu=${FAULT_NPU}"

python3 - "${LOCAL_IP}" "${ITS_HTTP_PORT_START}" "${DP_SIZE}" "${TP_SIZE}" \
    "${NUM_NPUS}" "${FAULT_NPU}" "${DEPLOY_TYPE}" <<'PY'
import json
import socket
import sys
import urllib.error
import urllib.request
import uuid

local_ip, http_base_raw, dp_raw, tp_raw, num_npus_raw, fault_raw, deploy_type = sys.argv[1:8]
http_base = int(http_base_raw)
dp_size = int(dp_raw)
tp_size = int(tp_raw)
num_npus = int(num_npus_raw)
fault_npu = int(fault_raw)
if not 0 <= fault_npu < tp_size:
    print(f"[trigger-p-direct] FAULT_NPU={fault_npu} must be in [0, {tp_size})")
    sys.exit(1)

generation = uuid.uuid4().hex
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.bind((local_ip, 0))
    barrier_master_port = probe.getsockname()[1]
finally:
    probe.close()

engine_parallel_config = []
for rank in range(dp_size):
    engine_parallel_config.append({
        "executor_id": str(rank),
        "dp": dp_size,
        "tp": tp_size,
        "data_parallel_rank": rank,
        "enable_expert_parallel": True,
        "new_dp": dp_size,
        "new_tp": 3 if rank == 0 else tp_size,
        "tp_asymmetric_shardings": [2, 1, 1] if rank == 0 else None,
    })

devices = [{
    "npu_id": npu_id,
    "device_ip": local_ip,
    "rank_id": str(npu_id),
    "npu_healthy": npu_id != fault_npu,
} for npu_id in range(num_npus)]
npu_healthy_state = [{
    "server_count": "1",
    "status": "completed",
    "version": "1.0",
    "server_list": [{"server_id": "server-1", "host_ip": local_ip, "device": devices}],
}]

failed = False
for executor_id in range(dp_size):
    its_port = http_base + executor_id * tp_size
    payload = {
        "deploy_type": deploy_type,
        "executor_id": str(executor_id),
        "engine_parallel_config": engine_parallel_config,
        "engine_npu_healthy_state": npu_healthy_state,
        "strategy_generation": generation,
        "barrier_master_port": barrier_master_port,
    }
    req = urllib.request.Request(
        f"http://127.0.0.1:{its_port}/api/v1/executor/deploy",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=60) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            print(f"[trigger-p-direct] executor_id={executor_id} port={its_port} HTTP {resp.status} -> {body}")
    except (urllib.error.URLError, OSError) as exc:
        failed = True
        print(f"[trigger-p-direct][ERROR] executor_id={executor_id} port={its_port} POST failed: {exc}")

print("[trigger-p-direct] OK" if not failed else "[trigger-p-direct] FAILED")
sys.exit(1 if failed else 0)
PY
