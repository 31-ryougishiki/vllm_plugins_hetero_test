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
PYTHON_BIN="${PYTHON_BIN:-python3}"
# 一次触发波的幂等 generation。上一次触发全部成功后会写入该文件，重跑
# 同一命令时复用同一 generation，executor 可安全跳过；若上一次只送达了
# 部分 executor（脚本以失败退出、没有写文件），重跑会生成新 generation，
# 已切到目标拓扑的 executor 也会再次参与全量 barrier/重启，把漏收的
# executor 拉回同一通信域。默认文件名包含完整目标拓扑：换 FAULT_NPU /
# DP/TP 后不会复用旧 generation。
STRATEGY_GENERATION_FILE="${STRATEGY_GENERATION_FILE:-/tmp/vllm_plugins_hetero_${DEPLOY_TYPE}_dp${DP_SIZE}_tp${TP_SIZE}_fault${FAULT_NPU}_gen}"

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi
if (( FAULT_NPU < 0 || FAULT_NPU >= TP_SIZE )); then
    echo "[ERROR] FAULT_NPU=${FAULT_NPU} must be a card of DP0 " \
        "(range [0, ${TP_SIZE}))" >&2
    exit 1
fi

echo "============================================================"
echo "[trigger] local ip     : ${LOCAL_IP}"
echo "[trigger] deploy type  : ${DEPLOY_TYPE}"
echo "[trigger] fault npu    : ${FAULT_NPU} (simulate=${SIMULATE_FAULT})"
echo "[trigger] target       : DP${DP_SIZE}TP(3,${TP_SIZE},${TP_SIZE},${TP_SIZE})"
echo "[trigger] ITS ports    : ${ITS_HTTP_PORT_START}..$((ITS_HTTP_PORT_START + (DP_SIZE - 1) * TP_SIZE))"
echo "============================================================"

"${PYTHON_BIN}" - "${LOCAL_IP}" "${FAULT_NPU}" "${SIMULATE_FAULT}" \
    "${DEPLOY_TYPE}" "${ITS_HTTP_PORT_START}" "${DP_SIZE}" "${TP_SIZE}" \
    "${NUM_NPUS}" "${STRATEGY_GENERATION_FILE}" <<'PY'
import json
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path

(
    local_ip,
    fault_npu_raw,
    simulate_fault_raw,
    deploy_type,
    http_port_base,
    dp_size_raw,
    tp_size_raw,
    num_npus_raw,
    generation_file,
) = sys.argv[1:10]

try:
    generation = Path(generation_file).read_text(encoding="utf-8").strip()
except FileNotFoundError:
    generation = __import__("uuid").uuid4().hex

# 为整波策略预选一个空闲 TCPStore 端口。先 bind(0) 再关闭，紧接 POST，
# 所有 executor 使用同一端口，避免局部 barrier 端口池在部分送达后漂移。
_probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    _probe.bind((local_ip, 0))
    barrier_master_port = _probe.getsockname()[1]
finally:
    _probe.close()

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
        "strategy_generation": generation,
        "barrier_master_port": barrier_master_port,
    }
    data = json.dumps(payload).encode("utf-8")
    url = f"http://127.0.0.1:{its_port}/api/v1/executor/deploy"
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=60) as resp:
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

Path(generation_file).write_text(generation, encoding="utf-8")
print(f"[trigger] strategy generation committed: {generation}")
print(
    "[trigger] all executors accepted the strategy. "
    "watch logs: grep -R 'restarting workers of EVERY DP instance' logs/prefill/"
)
PY
