#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# Decode 节点单独测试：DP16TP1 坏 1 卡 -> DP15TP1。
#
# 不依赖 P 节点、不依赖 PD 代理，只在 decode 节点上完成：
#   启动/复用 16 个 decode engine
#   -> 直接发基线请求
#   -> 触发本节点故障降级
#   -> 等待 15 个健康 engine
#   -> 直接发复测请求
#   -> 对比两次输出（temperature=0）
#
# 使用方式（decode 节点执行）：
#   LOCAL_IP=7.246.78.76 DECODE_FAULT_NPU=15 \
#   nohup bash run_decode_fault_alone.sh \
#     > /opt/its/z30055003/logs/decode/run_fault_alone.log 2>&1 &
#
# 环境变量：
#   WORK_ROOT / MODEL_PATH / LOCAL_IP / NIC /
#   DECODE_DP_SIZE / DECODE_VLLM_PORT_START / DECODE_FAULT_NPU /
#   DECODE_ITS_PORT_START / DECODE_LOG_DIR / RESTART_TIMEOUT /
#   FAULT_IDLE_TIMEOUT / REQUIRE_OUTPUT_MATCH / START_DECODE /
#   MAX_TOKENS / PYTHON_BIN

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
FAULT_IDLE_TIMEOUT="${FAULT_IDLE_TIMEOUT:-30}"
START_DECODE="${START_DECODE:-1}"
REQUIRE_OUTPUT_MATCH="${REQUIRE_OUTPUT_MATCH:-1}"
REQUEST_TEMPERATURE="${REQUEST_TEMPERATURE:-0.0}"
REQUEST_SEED="${REQUEST_SEED:-1024}"
PROMPT="${PROMPT:-请解释一下量子计算的基本原理。量子计算的基本原理是：}"
MAX_TOKENS="${MAX_TOKENS:-64}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_LOG_DIR="${TEST_LOG_DIR:-${WORK_ROOT}/logs/decode_fault_alone}"
PRE_OUTPUT="${TEST_LOG_DIR}/pre_fault.json"
POST_OUTPUT="${TEST_LOG_DIR}/post_fault.json"
NEW_DECODE_DP=$((DECODE_DP_SIZE - 1))

export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DECODE_DP_SIZE DECODE_VLLM_PORT_START DECODE_ITS_PORT_START
export DECODE_LOG_DIR PYTHON_BIN

mkdir -p "${TEST_LOG_DIR}"

if (( DECODE_FAULT_NPU < 0 || DECODE_FAULT_NPU >= DECODE_DP_SIZE )); then
    echo "[decode-alone][ERROR] DECODE_FAULT_NPU=${DECODE_FAULT_NPU} must be in [0, ${DECODE_DP_SIZE})" >&2
    exit 1
fi

echo "============================================================"
echo "[decode-alone] local ip : ${LOCAL_IP}"
echo "[decode-alone] topology : DP${DECODE_DP_SIZE}TP1 -> DP${NEW_DECODE_DP}TP1"
echo "[decode-alone] fault npu: ${DECODE_FAULT_NPU}"
echo "[decode-alone] vllm ports: ${DECODE_VLLM_PORT_START}..$((DECODE_VLLM_PORT_START + DECODE_DP_SIZE - 1))"
echo "[decode-alone] log dir  : ${TEST_LOG_DIR}"
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
    echo "[decode-alone] wait ${label} port=${port}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if check_http "${port}"; then
            echo "[decode-alone] ${label} is ready"
            return 0
        fi
        sleep 2
    done
    echo "[decode-alone][ERROR] timeout waiting for ${label} port=${port}" >&2
    return 1
}

all_http_ready() {
    local count="$1"
    local ready=0
    for ((rank = 0; rank < count; rank++)); do
        if check_http "$((DECODE_VLLM_PORT_START + rank))"; then
            ready=$((ready + 1))
        fi
    done
    [[ "${ready}" -eq "${count}" ]]
}

first_healthy_rank() {
    for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
        if (( rank == DECODE_FAULT_NPU )); then
            continue
        fi
        echo "${rank}"
        return 0
    done
    return 1
}

# ------------------------------------------------------------------
# 1. 启动/复用 16 个 decode engine。
# ------------------------------------------------------------------
if [[ "${START_DECODE}" == "1" ]]; then
    if all_http_ready "${DECODE_DP_SIZE}"; then
        echo "[decode-alone] ${DECODE_DP_SIZE} decode engines already healthy, skip launch"
    else
        echo "[decode-alone] launching DP${DECODE_DP_SIZE}TP1 decode ..."
        nohup bash "${SCRIPT_DIR}/launch_decode_pd.sh" \
            > "${TEST_LOG_DIR}/launch_decode.log" 2>&1 &
    fi
fi
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    wait_http "decode dp${rank} (initial)" \
        "$((DECODE_VLLM_PORT_START + rank))" 900 || exit 1
done

# ------------------------------------------------------------------
# 2. 基线请求（直接打 decode engine，不走 PD 代理）。
# ------------------------------------------------------------------
BASE_RANK="$(first_healthy_rank)"
BASE_PORT=$((DECODE_VLLM_PORT_START + BASE_RANK))
echo "[decode-alone] baseline request -> decode dp${BASE_RANK} port=${BASE_PORT}"
if ! "${PYTHON_BIN}" "${PD_HETERO_DIR}/send_pd_request.py" \
        --url "http://127.0.0.1:${BASE_PORT}/v1/completions" \
        --model dsv4 \
        --prompt "${PROMPT}" \
        --max-tokens "${MAX_TOKENS}" \
        --temperature "${REQUEST_TEMPERATURE}" \
        --seed "${REQUEST_SEED}" \
        --output "${PRE_OUTPUT}" \
        --timeout 600 \
        > "${TEST_LOG_DIR}/pre_request.log" 2>&1; then
    echo "[decode-alone][ERROR] baseline request failed" >&2
    cat "${TEST_LOG_DIR}/pre_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${TEST_LOG_DIR}/pre_request.log"

# ------------------------------------------------------------------
# 3. 触发本节点故障降级。
# ------------------------------------------------------------------
echo "[decode-alone] triggering decode DP${DECODE_DP_SIZE}TP1 -> DP${NEW_DECODE_DP}TP1"
if ! LOCAL_IP="${LOCAL_IP}" \
        DECODE_FAULT_NPU="${DECODE_FAULT_NPU}" \
        DECODE_DP_SIZE="${DECODE_DP_SIZE}" \
        DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START}" \
        DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
        DECODE_LOG_DIR="${DECODE_LOG_DIR}" \
        RESTART_TIMEOUT="${RESTART_TIMEOUT}" \
        bash "${SCRIPT_DIR}/trigger_decode_fault.sh" \
        | tee "${TEST_LOG_DIR}/trigger_decode.log"; then
    echo "[decode-alone][ERROR] decode fault trigger failed" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 4. 等待 15 个健康 engine。
# ------------------------------------------------------------------
for ((rank = 0; rank < DECODE_DP_SIZE; rank++)); do
    if (( rank == DECODE_FAULT_NPU )); then
        continue
    fi
    wait_http "decode dp${rank} (after degrade)" \
        "$((DECODE_VLLM_PORT_START + rank))" "${RESTART_TIMEOUT}" || exit 1
done

# 故障 executor 应进入空转状态。若其永久不可达，此检查只做短时 best-effort，
# 不允许拖慢健康 executor 的复测请求。
wait_marker_or_warn() {
    local log_file="$1"
    local marker="$2"
    local timeout="${3:-30}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if grep -q "${marker}" "${log_file}" 2>/dev/null; then
            echo "[decode-alone] fault executor marker found: '${marker}'"
            return 0
        fi
        sleep 2
    done
    echo "[decode-alone][WARN] fault executor marker '${marker}' not found in ${log_file} within ${timeout}s" >&2
    return 1
}
wait_marker_or_warn \
    "${DECODE_LOG_DIR}/dp${DECODE_FAULT_NPU}.log" \
    "Idle mode (dp=0)" \
    "${FAULT_IDLE_TIMEOUT}" || true

# ------------------------------------------------------------------
# 5. 复测请求（打到同一个非故障 rank，便于确定性对比）。
# ------------------------------------------------------------------
POST_RANK="$(first_healthy_rank)"
POST_PORT=$((DECODE_VLLM_PORT_START + POST_RANK))
echo "[decode-alone] post-degrade request -> decode dp${POST_RANK} port=${POST_PORT}"
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
    echo "[decode-alone][ERROR] post-degrade request failed" >&2
    cat "${TEST_LOG_DIR}/post_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${TEST_LOG_DIR}/post_request.log"

# ------------------------------------------------------------------
# 6. 对比两次输出。
# ------------------------------------------------------------------
echo "[decode-alone] comparing pre/post outputs ..."
"${PYTHON_BIN}" - "${PRE_OUTPUT}" "${POST_OUTPUT}" "${REQUIRE_OUTPUT_MATCH}" <<'PY'
import json
import sys

pre_path, post_path, require_match = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
pre = json.load(open(pre_path, encoding="utf-8"))
post = json.load(open(post_path, encoding="utf-8"))
pre_text = (pre.get("choices") or [{}])[0].get("text") or ""
post_text = (post.get("choices") or [{}])[0].get("text") or ""
print(f"PRE_TEXT={pre_text!r}")
print(f"POST_TEXT={post_text!r}")
print(f"MATCH={pre_text == post_text}")

if not post_text:
    print("[FAIL] post-degrade output is empty")
    sys.exit(1)
if require_match and pre_text != post_text:
    print("[FAIL] decode degrade output differs from baseline")
    sys.exit(2)
if require_match:
    print("[PASS] decode DP16TP1 -> DP15TP1 output is identical to baseline")
else:
    print("[WARN] REQUIRE_OUTPUT_MATCH=0")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    echo "[decode-alone] test failed (rc=${RC})" >&2
    exit ${RC}
fi

echo "============================================================"
echo "[decode-alone] PASS: decode degraded by one NPU."
echo "  baseline : ${PRE_OUTPUT}"
echo "  degraded : ${POST_OUTPUT}"
echo "  logs     : ${TEST_LOG_DIR}"
echo "============================================================"
exit 0
