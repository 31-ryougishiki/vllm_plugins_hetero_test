#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 2：decode 节点坏 1 卡，prefill 节点保持不变。
#
# 在 D 节点本地执行。向健康 decode executor 的 ITS HTTP 端口下发
# PD_REBUILD 策略（策略 payload 仍包含全部 16 条 config，供存活组
# barrier 计算 scale-to-zero rank）：
#   - executor 0..14: DP16 -> DP15，TP1 保持不变；
#   - executor 15（默认故障卡 NPU 15）: new_tp=0/new_dp=0，空转退出；
#     该 executor 只做 best-effort 下发，连接失败不阻塞健康 executor。
#
# 使用方式（decode 节点执行）：
#   bash decode/trigger_decode_fault.sh
#   DECODE_FAULT_NPU=15 bash decode/trigger_decode_fault.sh
#
# 环境变量：
#   LOCAL_IP / DECODE_DP_SIZE / DECODE_TP_SIZE / NUM_NPUS /
#   DECODE_FAULT_NPU / DECODE_ITS_PORT_START / DEPLOY_TYPE /
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
DEPLOY_TYPE="${DEPLOY_TYPE:-PD_REBUILD}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
# 只有所有健康 executor 和故障 executor 都收到策略时才提交 generation；
# 故障 executor 不可达时脚本仍按 best-effort 语义继续，但不提交
# generation，后续重跑会生成新 generation 并触发完整重建。
# 文件名包含目标拓扑，避免换故障卡/DP 后复用旧 generation。
STRATEGY_GENERATION_FILE="${STRATEGY_GENERATION_FILE:-/tmp/vllm_plugins_decode_${DEPLOY_TYPE}_dp${DECODE_DP_SIZE}_tp${DECODE_TP_SIZE}_fault${DECODE_FAULT_NPU}_gen}"
NEW_DECODE_DP=$((DECODE_DP_SIZE - 1))

if [[ -z "${LOCAL_IP}" ]]; then
    echo "[trigger-decode][ERROR] cannot detect local ip, please export LOCAL_IP" >&2
    exit 1
fi
if (( DECODE_FAULT_NPU < 0 || DECODE_FAULT_NPU >= DECODE_DP_SIZE )); then
    echo "[trigger-decode][ERROR] DECODE_FAULT_NPU=${DECODE_FAULT_NPU} must be in [0, ${DECODE_DP_SIZE})" >&2
    exit 1
fi

echo "============================================================"
echo "[trigger-decode] local ip       : ${LOCAL_IP}"
echo "[trigger-decode] deploy type    : ${DEPLOY_TYPE}"
echo "[trigger-decode] fault npu      : ${DECODE_FAULT_NPU}"
echo "[trigger-decode] target         : DP${DECODE_DP_SIZE}TP${DECODE_TP_SIZE} -> DP$((DECODE_DP_SIZE - 1))TP${DECODE_TP_SIZE}"
echo "[trigger-decode] ITS ports      : ${DECODE_ITS_PORT_START}..$((DECODE_ITS_PORT_START + DECODE_DP_SIZE - 1))"
echo "[trigger-decode] log dir        : ${DECODE_LOG_DIR}"
echo "============================================================"

# 在向 executor 下发策略前快照健康 rank 的日志计数。重复执行场景时日志
# 是追加的，且幂等短路日志可能在下发后立刻写出；等待函数必须使用触发前
# 的计数作为基线，而不是调用时刻的计数。
declare -a BARRIER_BASELINE=()
declare -a RESTART_BASELINE=()
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    if (( rank == DECODE_FAULT_NPU )); then
        continue
    fi
    log_file="${DECODE_LOG_DIR}/dp${rank}.log"
    restart_count="$(grep -c -e 'restarting workers of EVERY DP instance' \
        -e 'skipping redundant worker restart' "${log_file}" 2>/dev/null || true)"
    barrier_count="$(grep -c -e 'Full-restart barrier passed' \
        -e 'skipping redundant worker restart' "${log_file}" 2>/dev/null || true)"
    restart_count="${restart_count//[^0-9]/}"; [[ -n "${restart_count}" ]] || restart_count=0
    barrier_count="${barrier_count//[^0-9]/}"; [[ -n "${barrier_count}" ]] || barrier_count=0
    RESTART_BASELINE[${rank}]="${restart_count}"
    BARRIER_BASELINE[${rank}]="${barrier_count}"
    echo "[trigger-decode] pre-trigger marker baseline dp${rank}: " \
        "restart=${restart_count} barrier=${barrier_count}"
done

"${PYTHON_BIN}" - "${LOCAL_IP}" "${DECODE_FAULT_NPU}" "${DEPLOY_TYPE}" \
    "${DECODE_ITS_PORT_START}" "${DECODE_DP_SIZE}" "${DECODE_TP_SIZE}" \
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
    deploy_type,
    its_port_base,
    dp_size_raw,
    tp_size_raw,
    num_npus_raw,
    generation_file,
) = sys.argv[1:9]

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

fault_npu = int(fault_npu_raw)
its_port_base = int(its_port_base)
dp_size = int(dp_size_raw)
tp_size = int(tp_size_raw)
num_npus = int(num_npus_raw)
new_dp = dp_size - 1

engine_parallel_config = []
for rank in range(dp_size):
    if rank == fault_npu:
        engine_parallel_config.append(
            {
                "executor_id": str(rank),
                "dp": dp_size,
                "tp": tp_size,
                "data_parallel_rank": rank,
                "enable_expert_parallel": True,
                # 该 executor 没有可用 NPU，缩到零。
                "new_dp": 0,
                "new_tp": 0,
                "tp_asymmetric_shardings": None,
            }
        )
    else:
        engine_parallel_config.append(
            {
                "executor_id": str(rank),
                "dp": dp_size,
                "tp": tp_size,
                "data_parallel_rank": rank,
                "enable_expert_parallel": True,
                "new_dp": new_dp,
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
            "npu_healthy": npu_id != fault_npu,
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
fault_delivered = False
for executor_id in range(dp_size):
    its_port = its_port_base + executor_id
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
        request_timeout = 10 if executor_id == fault_npu else 60
        with opener.open(req, timeout=request_timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            print(
                f"[trigger-decode] executor_id={executor_id} port={its_port} "
                f"HTTP {resp.status} -> {body}"
            )
            if executor_id == fault_npu:
                fault_delivered = True
    except (urllib.error.URLError, OSError) as exc:
        if executor_id == fault_npu:
            # 故障 executor 可能永久不可达。健康 executor 的存活组 barrier
            # 不再需要它参与，所以只告警不阻塞。
            print(
                f"[trigger-decode][WARN] fault executor_id={executor_id} "
                f"port={its_port} POST failed: {exc}; continuing without it."
            )
        else:
            failed = True
            print(
                f"[trigger-decode][ERROR] executor_id={executor_id} "
                f"port={its_port} POST failed: {exc}"
            )

if failed:
    print("[trigger-decode] FAILED: at least one healthy decode executor did not accept the strategy.")
    sys.exit(1)

print("[trigger-decode] all healthy decode executors accepted the strategy.")
if fault_delivered:
    Path(generation_file).write_text(generation, encoding="utf-8")
    print("[trigger-decode] fault executor accepted the scale-to-zero strategy.")
    print(f"[trigger-decode] strategy generation committed: {generation}")
else:
    print("[trigger-decode] fault executor was not reachable; healthy executors will continue independently.")
    print("[trigger-decode] strategy generation NOT committed; a later rerun will force a full rebuild.")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    exit ${RC}
fi

wait_log_marker() {
    local log_file="$1"
    local marker="$2"
    local timeout="${3:-${RESTART_TIMEOUT}}"
    shift 3
    # 兼容旧式 [alt_marker...] 与新式 [baseline] [alt_marker...] 调用。
    local baseline=""
    local -a grep_args=("-c" "-e" "${marker}")
    if [[ "$#" -ge 1 && ( -z "${1}" || "${1}" =~ ^[0-9]+$ ) ]]; then
        baseline="${1}"
        shift
    fi
    local alt
    for alt in "$@"; do
        [[ -n "${alt}" ]] && grep_args+=("-e" "${alt}")
    done
    local before
    if [[ -n "${baseline}" ]]; then
        before="${baseline}"
    else
        before="$(grep "${grep_args[@]}" "${log_file}" 2>/dev/null || true)"
        before="${before//[^0-9]/}"
        [[ -n "${before}" ]] || before=0
    fi
    for _attempt in $(seq 1 $((timeout / 2))); do
        local now
        now="$(grep "${grep_args[@]}" "${log_file}" 2>/dev/null || true)"
        now="${now//[^0-9]/}"
        [[ -n "${now}" ]] || now=0
        if [[ "${now}" -gt "${before}" ]]; then
            echo "[trigger-decode] found new '${marker}' in ${log_file} (${before} -> ${now})"
            return 0
        fi
        sleep 2
    done
    echo "[trigger-decode][ERROR] timeout waiting for new '${marker}' in ${log_file} (baseline count=${before})" >&2
    return 1
}

echo "[trigger-decode] waiting for full-restart barrier and restart markers ..."
# 等待 marker 失败意味着本次触发波没有被完整执行，必须丢弃已提交的
# generation：否则重跑会复用同一 generation，已执行 executor 会幂等跳过，
# 未执行/执行失败的 executor 永远无法重新进入完整重建流程。
fail_wait() {
    rm -f "${STRATEGY_GENERATION_FILE}"
    echo "[trigger-decode][ERROR] marker wait failed; generation discarded" >&2
    exit 1
}
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    if (( rank == DECODE_FAULT_NPU )); then
        # 故障 executor 不参与存活组 barrier，也不再阻塞本脚本：
        # 不等待它的任何 marker（永久不可达时同样通过）。
        continue
    fi
    log_file="${DECODE_LOG_DIR}/dp${rank}.log"
    wait_log_marker "${log_file}" "restarting workers of EVERY DP instance" \
        "${RESTART_TIMEOUT}" "${RESTART_BASELINE[${rank}]}" \
        "skipping redundant worker restart" || fail_wait
    wait_log_marker "${log_file}" "Full-restart barrier passed" \
        "${RESTART_TIMEOUT}" "${BARRIER_BASELINE[${rank}]}" \
        "skipping redundant worker restart" || fail_wait
done

echo "[trigger-decode] waiting for the remaining ${NEW_DECODE_DP} decode engines ..."
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    if (( rank == DECODE_FAULT_NPU )); then
        continue
    fi
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
        echo "[trigger-decode][ERROR] decode engine rank=${rank} port=${port} did not become healthy" >&2
        exit 1
    fi
done

echo "[trigger-decode] decode DP${NEW_DECODE_DP}TP${DECODE_TP_SIZE} restart completed."
echo "[trigger-decode] healthy executors no longer depend on fault executor ${DECODE_FAULT_NPU}."
