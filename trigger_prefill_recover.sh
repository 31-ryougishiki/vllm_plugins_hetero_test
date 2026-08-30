#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 手动触发 prefill 异构 DP4TP(3,4,4,4) -> 对称 DP4TP4 恢复。
#
# 与 trigger_hetero_restart.sh 相反：向 4 个 executor 下发 RECOVER 策略，
# 所有 executor 恢复到启动时的对称 DP4TP4 布局。恢复后：
#   global world_size = 16
#   DP0: npu 0..3   tp=4
#   DP1: npu 4..7   tp=4
#   DP2: npu 8..11  tp=4
#   DP3: npu 12..15 tp=4
#
# 使用方式：
#   bash trigger_prefill_recover.sh
#
# 环境变量：
#   LOCAL_IP / ITS_HTTP_PORT_START / DP_SIZE / TP_SIZE / NUM_NPUS

set -euo pipefail

LOCAL_IP="${LOCAL_IP:-${VLLM_HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
NUM_NPUS="${NUM_NPUS:-16}"
DEPLOY_TYPE="${DEPLOY_TYPE:-RECOVER}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
# 同 trigger_hetero_restart.sh：仅在全部 executor POST 成功后提交
# generation；部分失败时重跑会生成新 generation 并触发完整重建。
# 文件名包含目标拓扑，避免换 DP/TP 后复用旧 generation。
STRATEGY_GENERATION_FILE="${STRATEGY_GENERATION_FILE:-/tmp/vllm_plugins_prefill_${DEPLOY_TYPE}_dp${DP_SIZE}_tp${TP_SIZE}_gen}"

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[trigger-recover][ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi

echo "============================================================"
echo "[trigger-recover] local ip     : ${LOCAL_IP}"
echo "[trigger-recover] deploy type  : ${DEPLOY_TYPE}"
echo "[trigger-recover] target       : DP${DP_SIZE}TP${TP_SIZE} (symmetric)"
echo "[trigger-recover] ITS ports    : ${ITS_HTTP_PORT_START}..$((ITS_HTTP_PORT_START + (DP_SIZE - 1) * TP_SIZE))"
echo "============================================================"

"${PYTHON_BIN}" - "${LOCAL_IP}" "${DEPLOY_TYPE}" "${ITS_HTTP_PORT_START}" \
    "${DP_SIZE}" "${TP_SIZE}" "${NUM_NPUS}" "${STRATEGY_GENERATION_FILE}" <<'PY'
import json
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path

(
    local_ip,
    deploy_type,
    http_port_base,
    dp_size_raw,
    tp_size_raw,
    num_npus_raw,
    generation_file,
) = sys.argv[1:8]

try:
    generation = Path(generation_file).read_text(encoding="utf-8").strip()
except FileNotFoundError:
    generation = __import__("uuid").uuid4().hex

_probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    _probe.bind((local_ip, 0))
    barrier_master_port = _probe.getsockname()[1]
finally:
    _probe.close()

http_port_base = int(http_port_base)
dp_size = int(dp_size_raw)
tp_size = int(tp_size_raw)
num_npus = int(num_npus_raw)

# RECOVER 时每个 conf 的 dp/tp/data_parallel_rank 都等于备份的对称配置，
# new_dp/new_tp 为目标拓扑。executor._get_engine_parallel_config 会断言
# 这些字段与第一次 DEGRADE/PD_REBUILD 前保存的 backup_parallel_config 一致。
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
        # RECOVER 表示故障卡已经恢复，所有 NPU 都是健康的。
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
                f"[trigger-recover] executor_id={executor_id} port={its_port} "
                f"HTTP {resp.status} -> {body}"
            )
    except (urllib.error.URLError, OSError) as exc:
        failed = True
        print(
            f"[trigger-recover][ERROR] executor_id={executor_id} "
            f"port={its_port} POST failed: {exc}"
        )

if failed:
    print("[trigger-recover] FAILED: at least one executor did not receive the strategy.")
    sys.exit(1)

Path(generation_file).write_text(generation, encoding="utf-8")
print(f"[trigger-recover] strategy generation committed: {generation}")
print(
    "[trigger-recover] all executors accepted the strategy. "
    "watch logs: grep -R 'restarting workers of EVERY DP instance' logs/prefill/"
)
PY
