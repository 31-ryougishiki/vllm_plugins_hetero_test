#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 1：prefill 节点转异构，decode 节点不变。
#
# 在 prefill 节点执行。脚本假设：
#   - decode 节点已用 decode/launch_decode_pd.sh 拉起 DP16TP1（保持不变）；
#   - prefill 节点已安装 vllm_plugins，并使用根目录
#     launch_prefill_hetero_test.sh 初始拉起对称 DP4TP4；
#   - 本脚本负责：基线请求 -> 下发异构策略 -> 等待全量重启与 KV 元数据恢复
#     -> 复测请求 -> 对比两次输出。
#
# 使用方式（prefill 节点）：
#   nohup bash run_scenario1.sh > /opt/its/z30055003/logs/pd_scenario1/run.log 2>&1 &
#
# 关键环境变量：
#   DECODE_HOST               decode 节点 IP（必填）
#   START_PREFILL / START_PROXY  默认 1，脚本会自动拉起 P 与代理
#   REQUIRE_OUTPUT_MATCH      默认 1，异构前后输出必须完全一致
#   FAULT_NPU                 默认 3（DP0 内故障卡）
#   其余端口/路径变量见脚本头部。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"

# P 端（初始对称 DP4TP4，与根目录 launch_prefill_hetero_test.sh 一致）。
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
NUM_NPUS="${NUM_NPUS:-16}"
VLLM_PORT_START="${VLLM_PORT_START:-9000}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
PREFILL_LOG_DIR="${PREFILL_LOG_DIR:-${WORK_ROOT}/logs/prefill}"

# D 端（保持 DP16TP1 不变）。
DECODE_HOST="${DECODE_HOST:?export DECODE_HOST=<decode-node-ip>}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"

# 代理（跑在 prefill 节点）。
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-8000}"
PROXY_URL="${PROXY_URL:-http://${PROXY_HOST}:${PROXY_PORT}/v1/completions}"

# 场景控制。
START_PREFILL="${START_PREFILL:-1}"
START_PROXY="${START_PROXY:-1}"
FAULT_NPU="${FAULT_NPU:-3}"
DEPLOY_TYPE="${DEPLOY_TYPE:-PD_REBUILD}"
REQUIRE_OUTPUT_MATCH="${REQUIRE_OUTPUT_MATCH:-1}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
PROMPT="${PROMPT:-请解释一下量子计算的基本原理。量子计算的基本原理是：}"
MAX_TOKENS="${MAX_TOKENS:-100}"

SCENARIO_LOG_DIR="${SCENARIO_LOG_DIR:-${WORK_ROOT}/logs/pd_scenario1}"
PRE_OUTPUT="${SCENARIO_LOG_DIR}/pre_hetero.json"
POST_OUTPUT="${SCENARIO_LOG_DIR}/post_hetero.json"
PYTHON_BIN="${PYTHON_BIN:-python3}"

# 子脚本（P 启动 / 代理 / trigger）通过环境继承这些覆盖值。
export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DP_SIZE TP_SIZE NUM_NPUS
export VLLM_PORT_START ITS_HTTP_PORT_START
export DECODE_HOST DECODE_DP_SIZE DECODE_VLLM_PORT_START
export PROXY_HOST PROXY_PORT
export PYTHON_BIN

mkdir -p "${SCENARIO_LOG_DIR}"

echo "============================================================"
echo "[scenario1] prefill node: ${LOCAL_IP}  (DP4TP4 -> DP4TP(3,4,4,4))"
echo "[scenario1] decode node : ${DECODE_HOST} (DP${DECODE_DP_SIZE}TP1 unchanged)"
echo "[scenario1] proxy       : ${PROXY_URL}"
echo "[scenario1] prompt      : ${PROMPT}"
echo "[scenario1] max_tokens  : ${MAX_TOKENS}"
echo "[scenario1] output dir  : ${SCENARIO_LOG_DIR}"
echo "============================================================"

check_http() {
    local host="$1"
    local port="$2"
    local path="${3:-/health}"
    "${PYTHON_BIN}" - "${host}" "${port}" "${path}" <<'PY'
import sys
import urllib.request

host, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(f"http://{host}:{port}{path}", timeout=5) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
}

wait_http() {
    local label="$1"
    local host="$2"
    local port="$3"
    local path="${4:-/health}"
    local timeout="${5:-600}"
    echo "[scenario1] wait ${label} http://${host}:${port}${path} (${timeout}s)"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if check_http "${host}" "${port}" "${path}"; then
            echo "[scenario1] ${label} is ready"
            return 0
        fi
        sleep 2
    done
    echo "[scenario1][ERROR] timeout waiting for ${label} http://${host}:${port}${path}" >&2
    return 1
}

wait_log_marker() {
    local label="$1"
    local log_file="$2"
    local marker="$3"
    local timeout="${4:-600}"
    echo "[scenario1] wait ${label} marker in ${log_file}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if grep -q "${marker}" "${log_file}" 2>/dev/null; then
            echo "[scenario1] ${label}: found '${marker}'"
            return 0
        fi
        sleep 2
    done
    echo "[scenario1][ERROR] timeout waiting for '${marker}' in ${log_file}" >&2
    return 1
}

all_http_ready() {
    local host="$1"
    local port_start="$2"
    local count="$3"
    local path="${4:-/health}"
    local ready=0
    for ((i = 0; i < count; i++)); do
        if check_http "${host}" "$((port_start + i))" "${path}"; then
            ready=$((ready + 1))
        fi
    done
    [[ "${ready}" -eq "${count}" ]]
}

# ------------------------------------------------------------------
# 1. 确保 P 端对称服务已拉起。
# ------------------------------------------------------------------
if [[ "${START_PREFILL}" == "1" ]]; then
    if all_http_ready "127.0.0.1" "${VLLM_PORT_START}" "${DP_SIZE}"; then
        echo "[scenario1] prefill engines already healthy, skip launch"
    else
        echo "[scenario1] launching symmetric prefill DP${DP_SIZE}TP${TP_SIZE} ..."
        nohup env LOG_DIR="${PREFILL_LOG_DIR}" \
            bash "${ROOT_SCRIPT_DIR}/launch_prefill_hetero_test.sh" \
            > "${SCENARIO_LOG_DIR}/launch_prefill.log" 2>&1 &
    fi
fi
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    wait_http "prefill dp${dp_rank}" "127.0.0.1" "$((VLLM_PORT_START + dp_rank))" \
        /health 900 || exit 1
done

# ------------------------------------------------------------------
# 2. 确认 D 端 16 个 decode engine 全部在线且保持 DP16TP1。
# ------------------------------------------------------------------
for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    wait_http "decode dp${dp_rank}" "${DECODE_HOST}" \
        "$((DECODE_VLLM_PORT_START + dp_rank))" /health 900 || exit 1
done
echo "[scenario1] decode side: ${DECODE_DP_SIZE} engines healthy (DP${DECODE_DP_SIZE}TP1, unchanged)"

# ------------------------------------------------------------------
# 3. 确保代理在线（代理在 prefill 节点，端口默认 8000）。
# ------------------------------------------------------------------
if [[ "${START_PROXY}" == "1" ]]; then
    if check_http "${PROXY_HOST}" "${PROXY_PORT}" /healthcheck; then
        echo "[scenario1] proxy already healthy, skip launch"
    else
        echo "[scenario1] starting PD load-balance proxy ..."
        nohup env DECODE_HOST="${DECODE_HOST}" \
            bash "${SCRIPT_DIR}/proxy/start_proxy_pd.sh" \
            > "${SCENARIO_LOG_DIR}/proxy.log" 2>&1 &
    fi
fi
wait_http "proxy" "${PROXY_HOST}" "${PROXY_PORT}" /healthcheck 120 || exit 1

# ------------------------------------------------------------------
# 4. 异构触发前的基线请求（对称 P + 不变 D）。
# ------------------------------------------------------------------
echo "[scenario1] baseline request (symmetric prefill) ..."
if ! "${PYTHON_BIN}" "${SCRIPT_DIR}/send_pd_request.py" \
        --url "${PROXY_URL}" \
        --model dsv4 \
        --prompt "${PROMPT}" \
        --max-tokens "${MAX_TOKENS}" \
        --output "${PRE_OUTPUT}" \
        --timeout 600 \
        > "${SCENARIO_LOG_DIR}/pre_request.log" 2>&1; then
    echo "[scenario1][ERROR] baseline request failed" >&2
    cat "${SCENARIO_LOG_DIR}/pre_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${SCENARIO_LOG_DIR}/pre_request.log"

# ------------------------------------------------------------------
# 5. 只对 P 端下发异构重启策略。
# ------------------------------------------------------------------
echo "[scenario1] triggering prefill DP4TP4 -> DP4TP(3,4,4,4) ..."
if ! LOCAL_IP="${LOCAL_IP}" \
        ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START}" \
        DP_SIZE="${DP_SIZE}" \
        TP_SIZE="${TP_SIZE}" \
        NUM_NPUS="${NUM_NPUS}" \
        FAULT_NPU="${FAULT_NPU}" \
        DEPLOY_TYPE="${DEPLOY_TYPE}" \
        bash "${ROOT_SCRIPT_DIR}/trigger_hetero_restart.sh" \
        | tee "${SCENARIO_LOG_DIR}/trigger.log"; then
    echo "[scenario1][ERROR] trigger_hetero_restart.sh failed" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 6. 等待 P 端完成全量重启、KV cache 重建与 Mooncake 元数据恢复。
# ------------------------------------------------------------------
echo "[scenario1] waiting for heterogeneous restart completion ..."
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    wait_http "prefill dp${dp_rank} (after restart)" "127.0.0.1" \
        "$((VLLM_PORT_START + dp_rank))" /health "${RESTART_TIMEOUT}" || exit 1
    wait_log_marker "dp${dp_rank} full-restart barrier" \
        "${PREFILL_LOG_DIR}/dp${dp_rank}.log" \
        "Full-restart barrier passed" "${RESTART_TIMEOUT}" || exit 1
    wait_log_marker "dp${dp_rank} KV connector metadata" \
        "${PREFILL_LOG_DIR}/dp${dp_rank}.log" \
        "KV connector metadata updated successfully" "${RESTART_TIMEOUT}" || exit 1
done

# 确认 D 端仍在服务（未被下发任何策略）。
for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    wait_http "decode dp${dp_rank} (unchanged)" "${DECODE_HOST}" \
        "$((DECODE_VLLM_PORT_START + dp_rank))" /health 120 || exit 1
done
echo "[scenario1] decode side still healthy after prefill restart (unchanged)"

# ------------------------------------------------------------------
# 7. 异构重启后的复测请求。
# ------------------------------------------------------------------
echo "[scenario1] post-restart request (heterogeneous prefill) ..."
if ! "${PYTHON_BIN}" "${SCRIPT_DIR}/send_pd_request.py" \
        --url "${PROXY_URL}" \
        --model dsv4 \
        --prompt "${PROMPT}" \
        --max-tokens "${MAX_TOKENS}" \
        --output "${POST_OUTPUT}" \
        --timeout 600 \
        > "${SCENARIO_LOG_DIR}/post_request.log" 2>&1; then
    echo "[scenario1][ERROR] post-restart request failed" >&2
    cat "${SCENARIO_LOG_DIR}/post_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${SCENARIO_LOG_DIR}/post_request.log"

# D 端日志级“未重启”校验（可选，SSH_DECODE 可用时会检查远端日志）。
if [[ "${CHECK_DECODE_UNCHANGED:-1}" == "1" ]]; then
    echo "[scenario1] checking decode side was not restarted ..."
    DECODE_HOST="${DECODE_HOST}" \
    DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
    DECODE_DP_SIZE="${DECODE_DP_SIZE}" \
        bash "${SCRIPT_DIR}/check_decode_unchanged.sh" || exit 1
fi

# ------------------------------------------------------------------
# 8. 对比两次输出（默认必须完全一致）。
# ------------------------------------------------------------------
echo "[scenario1] comparing pre/post outputs ..."
"${PYTHON_BIN}" - "${PRE_OUTPUT}" "${POST_OUTPUT}" "${REQUIRE_OUTPUT_MATCH}" <<'PY'
import json
import sys

pre_path, post_path, require_match = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
pre = json.load(open(pre_path, encoding="utf-8"))
post = json.load(open(post_path, encoding="utf-8"))
pre_text = (pre.get("choices") or [{}])[0].get("text") or ""
post_text = (post.get("choices") or [{}])[0].get("text") or ""
pre_reason = (pre.get("choices") or [{}])[0].get("finish_reason")
post_reason = (post.get("choices") or [{}])[0].get("finish_reason")

print(f"PRE_TEXT={pre_text!r}")
print(f"POST_TEXT={post_text!r}")
print(f"PRE_FINISH={pre_reason} POST_FINISH={post_reason}")
print(f"MATCH={pre_text == post_text}")

if not post_text:
    print("[FAIL] post-restart output is empty")
    sys.exit(1)
if require_match and pre_text != post_text:
    print("[FAIL] post-restart output differs from symmetric baseline")
    print("       check logs under logs/pd_scenario1 and logs/prefill")
    sys.exit(2)
if require_match:
    print("[PASS] prefill hetero restart output is identical to baseline")
else:
    print("[WARN] REQUIRE_OUTPUT_MATCH=0, text difference is not treated as failure")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    echo "[scenario1] test finished with failure (rc=${RC})" >&2
    exit ${RC}
fi

echo "============================================================"
echo "[scenario1] PASS: prefill heterogeneous restart completed;"
echo "            decode side remained DP${DECODE_DP_SIZE}TP1 unchanged."
echo "  baseline : ${PRE_OUTPUT}"
echo "  hetero   : ${POST_OUTPUT}"
echo "  logs     : ${SCENARIO_LOG_DIR}"
echo "============================================================"
exit 0
