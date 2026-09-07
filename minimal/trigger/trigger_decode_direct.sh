#!/usr/bin/env bash
# minimal/trigger/trigger_decode_direct.sh
# 直接向本机 16 个 decode executor 下发缩容策略：DP16TP1 -> DP15TP1。
# 在 decode 节点执行：bash minimal/trigger/trigger_decode_direct.sh
set -euo pipefail

LOCAL_IP="${LOCAL_IP:-7.246.78.76}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-18001}"
DP_SIZE="${DP_SIZE:-16}"
TP_SIZE="${TP_SIZE:-1}"
NUM_NPUS="${NUM_NPUS:-16}"
FAULT_NPU="${FAULT_NPU:-15}"
DEPLOY_TYPE="${DEPLOY_TYPE:-PD_REBUILD}"

echo "[trigger-d-direct] ${LOCAL_IP} DP${DP_SIZE}TP${TP_SIZE} -> DP$((DP_SIZE - 1))TP${TP_SIZE}, fault npu=${FAULT_NPU}"

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
if not 0 <= fault_npu < dp_size:
    print(f"[trigger-d-direct] FAULT_NPU={fault_npu} must be in [0, {dp_size})")
    sys.exit(1)

generation = uuid.uuid4().hex
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.bind((local_ip, 0))
    barrier_master_port = probe.getsockname()[1]
finally:
    probe.close()

new_dp = dp_size - 1
engine_parallel_config = []
for rank in range(dp_size):
    engine_parallel_config.append({
        "executor_id": str(rank),
        "dp": dp_size,
        "tp": tp_size,
        "data_parallel_rank": rank,
        "enable_expert_parallel": True,
        "new_dp": 0 if rank == fault_npu else new_dp,
        "new_tp": 0 if rank == fault_npu else tp_size,
        "tp_asymmetric_shardings": None,
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
        with opener.open(req, timeout=10 if executor_id == fault_npu else 60) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            print(f"[trigger-d-direct] executor_id={executor_id} port={its_port} HTTP {resp.status} -> {body}")
    except (urllib.error.URLError, OSError) as exc:
        if executor_id == fault_npu:
            print(f"[trigger-d-direct][WARN] fault executor_id={executor_id} port={its_port} POST failed: {exc}")
        else:
            failed = True
            print(f"[trigger-d-direct][ERROR] executor_id={executor_id} port={its_port} POST failed: {exc}")

print("[trigger-d-direct] OK" if not failed else "[trigger-d-direct] FAILED")
sys.exit(1 if failed else 0)
PY
