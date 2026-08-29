#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# Decode 节点单独测试：DP15TP1 坏卡恢复 -> DP16TP1。
#
# 前置条件：本节点已经执行过 run_decode_fault_alone.sh（或场景 2），
# 即 executor 15 处于 Idle mode，其余 15 个 engine 健康。脚本完成：
#   确认 15 个健康 engine + 1 个 idle executor
#   -> 触发 DP15TP1 -> DP16TP1 RECOVER
#   -> 等待 16 个 engine 健康
#   -> 直接发复测请求
#   -> 与降级前基线（默认 logs/decode_fault_alone/pre_fault.json）对比。
#
# 使用方式（decode 节点执行）：
#   LOCAL_IP=7.246.78.76 DECODE_FAULT_NPU=15 \
#   nohup bash run_decode_recover_alone.sh \
#     > /opt/its/z30055003/logs/decode/run_recover_alone.log 2>&1 &
#
# 环境变量：
#   WORK_ROOT / MODEL_PATH / LOCAL_IP / NIC /
#   DECODE_DP_SIZE / DECODE_VLLM_PORT_START / DECODE_FAULT_NPU /
#   DECODE_ITS_PORT_START / DECODE_LOG_DIR / RESTART_TIMEOUT /
#   RECOVER_BASELINE / REQUIRE_OUTPUT_MATCH / MAX_TOKENS / PYTHON_BIN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD_HETERO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_FAULT_NPU="${DECODE_FAULT_NPU:-15}"
DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START:-18001}"
DECODE_LOG_DIR="${DECODE_LOG_DIR:-${WORK_ROOT}/logs/decode}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
REQUIRE_OUTPUT_MATCH="${REQUIRE_OUTPUT_MATCH:-1}"
REQUEST_TEMPERATURE="${REQUEST_TEMPERATURE:-0.0}"
REQUEST_SEED="${REQUEST_SEED:-1024}"
PROMPT="${PROMPT:-请解释一下量子计算的基本原理。量子计算的基本原理是：}"
MAX_TOKENS="${MAX_TOKENS:-64}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_LOG_DIR="${TEST_LOG_DIR:-${WORK_ROOT}/logs/decode_recover_alone}"
PRE_OUTPUT="${RECOVER_BASELINE:-${WORK_ROOT}/logs/decode_fault_alone/pre_fault.json}"
POST_OUTPUT="${TEST_LOG_DIR}/post_recover.json"
NEW_DECODE_DP=$((DECODE_DP_SIZE - 1))

export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DECODE_DP_SIZE DECODE_VLLM_PORT_START DECODE_ITS_PORT_START
export DECODE_LOG_DIR PYTHON_BIN

mkdir -p "${TEST_LOG_DIR}"

if (( DECODE_FAULT_NPU < 0 || DECODE_FAULT_NPU >= DECODE_DP_SIZE )); then
    echo "[decode-recover][ERROR] DECODE_FAULT_NPU=${DECODE_FAULT_NPU} must be in [0, ${DECODE_DP_SIZE})" >&2
    exit 1
fi

echo "============================================================"
echo "[decode-recover] local ip : ${LOCAL_IP}"
echo "[decode-recover] topology : DP${NEW_DECODE_DP}TP1 -> DP${DECODE_DP_SIZE}TP1"
echo "[decode-recover] recovered npu: ${DECODE_FAULT_NPU}"
echo "[decode-recover] vllm ports: ${DECODE_VLLM_PORT_START}..$((DECODE_VLLM_PORT_START + DECODE_DP_SIZE - 1))"
echo "[decode-recover] baseline  : ${PRE_OUTPUT}"
echo "[decode-recover] log dir   : ${TEST_LOG_DIR}"
echo "============================================================"

check_http() {
    local port="$1"
    "${PYTHON_BIN}" - "${port}" <<'PY'
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
}

wait_http() {
    local label="$1"
    local port="$2"
    local timeout="${3:-600}"
    echo "[decode-recover] wait ${label} port=${port}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if check_http "${port}"; then
            echo "[decode-recover] ${label} is ready"
            return 0
        fi
        sleep 2
    done
    echo "[decode-recover][ERROR] timeout waiting for ${label} port=${port}" >&2
    return 1
}

wait_marker_or_warn() {
    local log_file="$1"
    local marker="$2"
    for _attempt in $(seq 1 $((RESTART_TIMEOUT / 2))); do
        if grep -q "${marker}" "${log_file}" 2>/dev/null; then
            echo "[decode-recover] marker found: '${marker}'"
            return 0
        fi
        sleep 2
    done
    echo "[decode-recover][WARN] marker '${marker}' not found in ${log_file}" >&2
    return 1
}

# ------------------------------------------------------------------
# 1. 确认当前处于场景 2 结束状态：15 个健康 engine + 1 个 idle executor。
# ------------------------------------------------------------------
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    if (( rank == DECODE_FAULT_NPU )); then
        wait_marker_or_warn "${DECODE_LOG_DIR}/dp${rank}.log" "Idle mode (dp=0)" || true
        continue
    fi
    wait_http "decode dp${rank} (before recover)" \
        "$((DECODE_VLLM_PORT_START + rank))" 300 || exit 1
done
echo "[decode-recover] current state: DP${NEW_DECODE_DP}TP1 healthy + executor ${DECODE_FAULT_NPU} idle"

# ------------------------------------------------------------------
# 2. 触发 DP15 -> DP16 恢复。
# ------------------------------------------------------------------
echo "[decode-recover] triggering decode DP${NEW_DECODE_DP}TP1 -> DP${DECODE_DP_SIZE}TP1"
if ! LOCAL_IP="${LOCAL_IP}" \
        DECODE_FAULT_NPU="${DECODE_FAULT_NPU}" \
        DECODE_DP_SIZE="${DECODE_DP_SIZE}" \
        DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START}" \
        DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
        DECODE_LOG_DIR="${DECODE_LOG_DIR}" \
        RESTART_TIMEOUT="${RESTART_TIMEOUT}" \
        bash "${SCRIPT_DIR}/trigger_decode_recover.sh" \
        | tee "${TEST_LOG_DIR}/trigger_recover.log"; then
    echo "[decode-recover][ERROR] decode recover trigger failed" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 3. 等待全部 16 个 engine 恢复。
# ------------------------------------------------------------------
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    wait_http "decode dp${rank} (after recover)" \
        "$((DECODE_VLLM_PORT_START + rank))" "${RESTART_TIMEOUT}" || exit 1
done

# ------------------------------------------------------------------
# 4. 复测请求（直接打到恢复的 executor 端口之外的健康 rank，保证对比公平）。
# ------------------------------------------------------------------
if (( DECODE_FAULT_NPU == 0 )); then
    POST_RANK=1
else
    POST_RANK=0
fi
POST_PORT=$((DECODE_VLLM_PORT_START + POST_RANK))
echo "[decode-recover] post-recover request -> decode dp${POST_RANK} port=${POST_PORT}"
if ! "${PYTHON_BIN}" "${PD_HETERO_DIR}/send_pd_request.py" \
        --url "http://127.0.0.1:${POST_PORT}/v1/completions" \
        --model dsv4 \
        --prompt "${PROMPT}" \
        --max-tokens "${MAX_TOKENS}" \
        --temperature "${REQUEST_TEMPERATURE}" \
        --seed "${REQUEST_SEED}" \
        --output "${POST_OUTPUT}" \
        --timeout 600 \
        > "${TEST_LOG_DIR}/post_request.log" 2>&1; then
    echo "[decode-recover][ERROR] post-recover request failed" >&2
    cat "${TEST_LOG_DIR}/post_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${TEST_LOG_DIR}/post_request.log"

# ------------------------------------------------------------------
# 5. 与降级前基线对比。
# ------------------------------------------------------------------
if [[ ! -f "${PRE_OUTPUT}" ]]; then
    echo "[decode-recover][WARN] baseline ${PRE_OUTPUT} not found, only checking non-empty output" >&2
    REQUIRE_OUTPUT_MATCH=0
fi
echo "[decode-recover] comparing recovered output with baseline ..."
"${PYTHON_BIN}" - "${PRE_OUTPUT}" "${POST_OUTPUT}" "${REQUIRE_OUTPUT_MATCH}" <<'PY'
import json
import sys

pre_path, post_path, require_match = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
post = json.load(open(post_path, encoding="utf-8"))
post_text = (post.get("choices") or [{}])[0].get("text") or ""

if require_match and pre_path:
    pre = json.load(open(pre_path, encoding="utf-8"))
    pre_text = (pre.get("choices") or [{}])[0].get("text") or ""
    print(f"PRE_TEXT={pre_text!r}")
else:
    pre_text = None
    print("PRE_TEXT=<skipped: no baseline or match disabled>")

print(f"POST_TEXT={post_text!r}")
print(f"MATCH={pre_text == post_text if pre_text is not None else 'N/A'}")

if not post_text:
    print("[FAIL] post-recover output is empty")
    sys.exit(1)
if require_match and pre_text is not None and pre_text != post_text:
    print("[FAIL] decode recover output differs from pre-degrade baseline")
    sys.exit(2)
if require_match:
    print("[PASS] decode DP15TP1 -> DP16TP1 output is identical to baseline")
else:
    print("[WARN] REQUIRE_OUTPUT_MATCH=0")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    echo "[decode-recover] test failed (rc=${RC})" >&2
    exit ${RC}
fi

echo "============================================================"
echo "[decode-recover] PASS: decode recovered to DP${DECODE_DP_SIZE}TP1."
echo "  baseline : ${PRE_OUTPUT}"
echo "  recovered: ${POST_OUTPUT}"
echo "  logs     : ${TEST_LOG_DIR}"
echo "============================================================"
exit 0
