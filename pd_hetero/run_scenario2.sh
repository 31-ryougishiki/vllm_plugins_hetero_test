#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 2：decode 节点坏 1 卡，prefill 节点保持不变。
#
# 在 prefill 节点执行。脚本假设：
#   - decode 节点已用 decode/launch_decode_pd.sh 拉起 DP16TP1；
#   - prefill 节点使用根目录 launch_prefill_hetero_test.sh 保持对称 DP4TP4；
#   - 本脚本负责：基线请求 -> 触发 D 端 DP16TP1 -> DP15TP1 降级
#     -> 从代理摘除故障 decoder -> PD 链路预热 -> 复测请求 -> 对比输出。
#
# 使用方式（prefill 节点）：
#   SSH_DECODE="root@7.246.78.76" DECODE_HOST=7.246.78.76 \
#   nohup bash run_scenario2.sh \
#     > /opt/its/z30055003/logs/pd_scenario2/run.log 2>&1 &
#
# 触发方式 TRIGGER_MODE：
#   ssh   通过 SSH_DECODE 在 D 节点执行 decode/trigger_decode_fault.sh（默认）
#   local D 与 P 同节点，直接在本地执行 trigger 脚本
#   skip  认为 D 已经完成降级，只做 P 侧复测与对比
#
# 关键环境变量：
#   DECODE_HOST / SSH_DECODE / DECODE_FAULT_NPU / TRIGGER_MODE /
#   REQUIRE_OUTPUT_MATCH / 以及 scenario1 相同的端口/路径变量。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"

# P 端（保持不变，对称 DP4TP4）。
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
NUM_NPUS="${NUM_NPUS:-16}"
VLLM_PORT_START="${VLLM_PORT_START:-9000}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
PREFILL_LOG_DIR="${PREFILL_LOG_DIR:-${WORK_ROOT}/logs/prefill}"

# D 端（DP16TP1 -> DP15TP1）。
DECODE_HOST="${DECODE_HOST:?export DECODE_HOST=<decode-node-ip>}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START:-18001}"
DECODE_LOG_DIR="${DECODE_LOG_DIR:-${WORK_ROOT}/logs/decode}"
DECODE_TEST_DIR="${DECODE_TEST_DIR:-${WORK_ROOT}/vllm_plugins_hetero_test/pd_hetero}"
DECODE_FAULT_NPU="${DECODE_FAULT_NPU:-15}"

# 代理。
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-8000}"
PROXY_URL="${PROXY_URL:-http://${PROXY_HOST}:${PROXY_PORT}/v1/completions}"
PROXY_API_HOST="${PROXY_API_HOST:-127.0.0.1}"

# 场景控制。
START_PREFILL="${START_PREFILL:-1}"
START_PROXY="${START_PROXY:-1}"
TRIGGER_MODE="${TRIGGER_MODE:-ssh}"
SSH_DECODE="${SSH_DECODE:-}"
REQUIRE_OUTPUT_MATCH="${REQUIRE_OUTPUT_MATCH:-1}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
WARMUP_RETRIES="${WARMUP_RETRIES:-30}"
WARMUP_INTERVAL="${WARMUP_INTERVAL:-10}"
# warmup 数量在基线前设为 DECODE_DP_SIZE，D 降级后设为 NEW_DECODE_DP。
WARMUP_REQUESTS="${WARMUP_REQUESTS:-${DECODE_DP_SIZE}}"
REQUEST_TEMPERATURE="${REQUEST_TEMPERATURE:-0.0}"
REQUEST_SEED="${REQUEST_SEED:-1024}"
D_DEGRADE_SETTLE_TIME="${D_DEGRADE_SETTLE_TIME:-30}"
PROMPT="${PROMPT:-请解释一下量子计算的基本原理。量子计算的基本原理是：}"
MAX_TOKENS="${MAX_TOKENS:-100}"

SCENARIO_LOG_DIR="${SCENARIO_LOG_DIR:-${WORK_ROOT}/logs/pd_scenario2}"
PRE_OUTPUT="${SCENARIO_LOG_DIR}/pre_decode_fault.json"
POST_OUTPUT="${SCENARIO_LOG_DIR}/post_decode_fault.json"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NEW_DECODE_DP=$((DECODE_DP_SIZE - 1))

export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DP_SIZE TP_SIZE NUM_NPUS VLLM_PORT_START ITS_HTTP_PORT_START
export DECODE_HOST DECODE_DP_SIZE DECODE_VLLM_PORT_START
export PROXY_HOST PROXY_PORT PYTHON_BIN

mkdir -p "${SCENARIO_LOG_DIR}"

echo "============================================================"
echo "[scenario2] prefill node: ${LOCAL_IP}  (DP4TP4 unchanged)"
echo "[scenario2] decode node : ${DECODE_HOST} (DP${DECODE_DP_SIZE}TP1 -> DP${NEW_DECODE_DP}TP1)"
echo "[scenario2] fault npu   : ${DECODE_FAULT_NPU}"
echo "[scenario2] trigger mode: ${TRIGGER_MODE}"
echo "[scenario2] proxy       : ${PROXY_URL}"
echo "[scenario2] output dir  : ${SCENARIO_LOG_DIR}"
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
    echo "[scenario2] wait ${label} http://${host}:${port}${path}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if check_http "${host}" "${port}" "${path}"; then
            echo "[scenario2] ${label} is ready"
            return 0
        fi
        sleep 2
    done
    echo "[scenario2][ERROR] timeout waiting for ${label}" >&2
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

run_warmup() {
    local label="$1"
    local log_file="${SCENARIO_LOG_DIR}/${label}_warmup.log"
    local successes=0
    local max_attempts=$((WARMUP_REQUESTS + WARMUP_RETRIES))
    echo "[scenario2] ${label}: warming up PD chain "
    echo "  (need ${WARMUP_REQUESTS} successful requests to cover all active decoders)"
    for attempt in $(seq 1 "${max_attempts}"); do
        if "${PYTHON_BIN}" "${SCRIPT_DIR}/send_pd_request.py" \
                --url "${PROXY_URL}" \
                --model dsv4 \
                --prompt "${PROMPT}" \
                --max-tokens 8 \
                --temperature "${REQUEST_TEMPERATURE}" \
                --seed "${REQUEST_SEED}" \
                --output "${SCENARIO_LOG_DIR}/${label}_warmup_${successes}.json" \
                --timeout 300 \
                > "${log_file}" 2>&1; then
            finish="$(grep '^FINISH_REASON=' "${log_file}" | tail -n 1 || true)"
            if [[ "${finish}" == "FINISH_REASON=recomputed" ]]; then
                echo "[scenario2] ${label}: warmup attempt=${attempt} still recomputed"
                sleep "${WARMUP_INTERVAL}"
                continue
            fi
            successes=$((successes + 1))
            echo "[scenario2] ${label}: warmup ${successes}/${WARMUP_REQUESTS} ${finish}"
            if (( successes >= WARMUP_REQUESTS )); then
                echo "[scenario2] ${label}: PD chain warmup completed"
                return 0
            fi
        else
            echo "[scenario2] ${label}: warmup attempt=${attempt} failed"
            sleep "${WARMUP_INTERVAL}"
        fi
    done
    echo "[scenario2][ERROR] ${label}: PD chain did not become ready "
    echo "  (only ${successes}/${WARMUP_REQUESTS} successful warmups)" >&2
    tail -n 20 "${log_file}" >&2 || true
    return 1
}

prefill_restart_marker_count() {
    local dp_rank="$1"
    grep -c "restarting workers of EVERY DP instance" \
        "${PREFILL_LOG_DIR}/dp${dp_rank}.log" 2>/dev/null || echo 0
}

remove_proxy_instance() {
    local host="$1"
    local port="$2"
    "${PYTHON_BIN}" - "${PROXY_API_HOST}" "${PROXY_PORT}" "${host}" "${port}" <<'PY'
import json
import sys
import urllib.request

proxy_host, proxy_port, host, port = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
payload = {"type": "decode", "instances": f"{host}:{port}"}
data = json.dumps(payload).encode("utf-8")
url = f"http://{proxy_host}:{proxy_port}/instances/remove"
req = urllib.request.Request(
    url, data=data, headers={"Content-Type": "application/json"}, method="POST"
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(req, timeout=30) as resp:
    body = resp.read().decode("utf-8", errors="replace")
print(body)
PY
}

# ------------------------------------------------------------------
# 1. 确保 P 端对称服务已拉起（场景 2 中 P 不触发任何策略）。
# ------------------------------------------------------------------
if [[ "${START_PREFILL}" == "1" ]]; then
    if all_http_ready "127.0.0.1" "${VLLM_PORT_START}" "${DP_SIZE}"; then
        echo "[scenario2] prefill engines already healthy, skip launch"
    else
        echo "[scenario2] launching symmetric prefill DP${DP_SIZE}TP${TP_SIZE} ..."
        nohup env LOG_DIR="${PREFILL_LOG_DIR}" \
            bash "${ROOT_SCRIPT_DIR}/launch_prefill_hetero_test.sh" \
            > "${SCENARIO_LOG_DIR}/launch_prefill.log" 2>&1 &
    fi
fi
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    wait_http "prefill dp${dp_rank}" "127.0.0.1" \
        "$((VLLM_PORT_START + dp_rank))" /health 900 || exit 1
done

# ------------------------------------------------------------------
# 2. 确认 D 端初始 DP16TP1 全部在线。
# ------------------------------------------------------------------
for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    wait_http "decode dp${dp_rank}" "${DECODE_HOST}" \
        "$((DECODE_VLLM_PORT_START + dp_rank))" /health 900 || exit 1
done
echo "[scenario2] decode initial state: DP${DECODE_DP_SIZE}TP1 healthy"

# ------------------------------------------------------------------
# 3. 确保代理在线。
# ------------------------------------------------------------------
if [[ "${START_PROXY}" == "1" ]]; then
    if check_http "${PROXY_HOST}" "${PROXY_PORT}" /healthcheck; then
        echo "[scenario2] proxy already healthy, skip launch"
    else
        echo "[scenario2] starting PD load-balance proxy ..."
        nohup env DECODE_HOST="${DECODE_HOST}" \
            bash "${SCRIPT_DIR}/proxy/start_proxy_pd.sh" \
            > "${SCENARIO_LOG_DIR}/proxy.log" 2>&1 &
    fi
fi
wait_http "proxy" "${PROXY_HOST}" "${PROXY_PORT}" /healthcheck 120 || exit 1

# ------------------------------------------------------------------
# 4. D 故障前的基线请求。
# ------------------------------------------------------------------
WARMUP_REQUESTS="${DECODE_DP_SIZE}"
run_warmup "baseline" || exit 1
echo "[scenario2] baseline request (DP16TP1 decode) ..."
if ! "${PYTHON_BIN}" "${SCRIPT_DIR}/send_pd_request.py" \
        --url "${PROXY_URL}" \
        --model dsv4 \
        --prompt "${PROMPT}" \
        --max-tokens "${MAX_TOKENS}" \
        --temperature "${REQUEST_TEMPERATURE}" \
        --seed "${REQUEST_SEED}" \
        --output "${PRE_OUTPUT}" \
        --timeout 600 \
        > "${SCENARIO_LOG_DIR}/pre_request.log" 2>&1; then
    echo "[scenario2][ERROR] baseline request failed" >&2
    cat "${SCENARIO_LOG_DIR}/pre_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${SCENARIO_LOG_DIR}/pre_request.log"

# 记录 P 端“已重启”日志基线，后面用于证明 P 保持未变。
BEFORE_PREFILL_MARKERS=()
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    BEFORE_PREFILL_MARKERS[${dp_rank}]="$(prefill_restart_marker_count "${dp_rank}")"
    echo "[scenario2] baseline prefill dp${dp_rank} restart-markers=${BEFORE_PREFILL_MARKERS[${dp_rank}]}"
done

# ------------------------------------------------------------------
# 5. 触发 D 端故障降级（只动 D，P 不接收策略）。
# ------------------------------------------------------------------
case "${TRIGGER_MODE}" in
    ssh)
        if [[ -z "${SSH_DECODE}" ]]; then
            echo "[scenario2][ERROR] TRIGGER_MODE=ssh requires SSH_DECODE=root@<decode-ip>" >&2
            exit 1
        fi
        echo "[scenario2] triggering decode fault via ssh ${SSH_DECODE} ..."
        if ! ssh "${SSH_DECODE}" \
            "cd '${DECODE_TEST_DIR}' && \
             LOCAL_IP='${DECODE_HOST}' NIC='${NIC}' \
             DECODE_FAULT_NPU='${DECODE_FAULT_NPU}' \
             DECODE_DP_SIZE='${DECODE_DP_SIZE}' \
             DECODE_ITS_PORT_START='${DECODE_ITS_PORT_START}' \
             DECODE_VLLM_PORT_START='${DECODE_VLLM_PORT_START}' \
             DECODE_LOG_DIR='${DECODE_LOG_DIR}' \
             RESTART_TIMEOUT='${RESTART_TIMEOUT}' \
             bash decode/trigger_decode_fault.sh" \
            | tee "${SCENARIO_LOG_DIR}/trigger_decode.log"; then
            echo "[scenario2][ERROR] remote decode trigger failed" >&2
            exit 1
        fi
        ;;
    local)
        echo "[scenario2] triggering decode fault locally ..."
        if ! LOCAL_IP="${DECODE_HOST}" \
                DECODE_FAULT_NPU="${DECODE_FAULT_NPU}" \
                DECODE_DP_SIZE="${DECODE_DP_SIZE}" \
                DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START}" \
                DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
                DECODE_LOG_DIR="${DECODE_LOG_DIR}" \
                RESTART_TIMEOUT="${RESTART_TIMEOUT}" \
                bash "${SCRIPT_DIR}/decode/trigger_decode_fault.sh" \
                | tee "${SCENARIO_LOG_DIR}/trigger_decode.log"; then
            echo "[scenario2][ERROR] local decode trigger failed" >&2
            exit 1
        fi
        ;;
    skip)
        echo "[scenario2] TRIGGER_MODE=skip: assuming decode fault was already triggered"
        ;;
    *)
        echo "[scenario2][ERROR] unknown TRIGGER_MODE=${TRIGGER_MODE}" >&2
        exit 1
        ;;
esac

if [[ "${TRIGGER_MODE}" != "ssh" && "${TRIGGER_MODE}" != "local" ]]; then
    echo "[scenario2] waiting ${D_DEGRADE_SETTLE_TIME}s for decode degradation to settle ..."
    sleep "${D_DEGRADE_SETTLE_TIME}"
fi

# ------------------------------------------------------------------
# 6. 确认 P 端仍未重启、D 端剩余 15 个 engine 健康。
# ------------------------------------------------------------------
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    wait_http "prefill dp${dp_rank} (unchanged)" "127.0.0.1" \
        "$((VLLM_PORT_START + dp_rank))" /health 120 || exit 1
done
for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    if (( dp_rank == DECODE_FAULT_NPU )); then
        continue
    fi
    wait_http "decode dp${dp_rank} (after degrade)" "${DECODE_HOST}" \
        "$((DECODE_VLLM_PORT_START + dp_rank))" /health "${RESTART_TIMEOUT}" || exit 1
done
echo "[scenario2] decode remaining engines: ${NEW_DECODE_DP}/${DECODE_DP_SIZE} healthy (fault rank ${DECODE_FAULT_NPU} excluded)"

# ------------------------------------------------------------------
# 7. 从代理摘除故障 decoder，避免后续请求轮询到空转 executor。
# ------------------------------------------------------------------
FAULT_DECODE_PORT=$((DECODE_VLLM_PORT_START + DECODE_FAULT_NPU))
echo "[scenario2] removing fault decoder ${DECODE_HOST}:${FAULT_DECODE_PORT} from proxy ..."
remove_proxy_instance "${DECODE_HOST}" "${FAULT_DECODE_PORT}" \
    | tee -a "${SCENARIO_LOG_DIR}/proxy_remove.log"

# ------------------------------------------------------------------
# 8. D 降级后的复测请求。
# ------------------------------------------------------------------
WARMUP_REQUESTS="${NEW_DECODE_DP}"
run_warmup "post_degrade" || exit 1
echo "[scenario2] post-degrade request (DP15TP1 decode) ..."
if ! "${PYTHON_BIN}" "${SCRIPT_DIR}/send_pd_request.py" \
        --url "${PROXY_URL}" \
        --model dsv4 \
        --prompt "${PROMPT}" \
        --max-tokens "${MAX_TOKENS}" \
        --temperature "${REQUEST_TEMPERATURE}" \
        --seed "${REQUEST_SEED}" \
        --output "${POST_OUTPUT}" \
        --timeout 600 \
        > "${SCENARIO_LOG_DIR}/post_request.log" 2>&1; then
    echo "[scenario2][ERROR] post-degrade request failed" >&2
    cat "${SCENARIO_LOG_DIR}/post_request.log" >&2
    exit 1
fi
grep "RESULT_TEXT=" "${SCENARIO_LOG_DIR}/post_request.log"

# ------------------------------------------------------------------
# 9. 确认 P 端日志没有新增“restarting workers”记录。
# ------------------------------------------------------------------
P_UNCHANGED=1
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    after_count="$(prefill_restart_marker_count "${dp_rank}")"
    echo "[scenario2] final prefill dp${dp_rank} restart-markers=${after_count}"
    if [[ "${after_count}" -ne "${BEFORE_PREFILL_MARKERS[${dp_rank}]}" ]]; then
        echo "[scenario2][FAIL] prefill dp${dp_rank} restarted during scenario2" >&2
        P_UNCHANGED=0
    fi
done
if [[ "${P_UNCHANGED}" -ne 1 ]]; then
    exit 1
fi
echo "[scenario2] prefill side unchanged (no new restart markers)"

# ------------------------------------------------------------------
# 10. 对比两次输出。
# ------------------------------------------------------------------
echo "[scenario2] comparing pre/post outputs ..."
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
    print("[FAIL] post-degrade output is empty")
    sys.exit(1)
if require_match and pre_text != post_text:
    print("[FAIL] post-degrade output differs from baseline")
    print("       check logs under logs/pd_scenario2, logs/prefill, logs/decode")
    sys.exit(2)
if require_match:
    print("[PASS] decode DP16TP1 -> DP15TP1 output is identical to baseline")
else:
    print("[WARN] REQUIRE_OUTPUT_MATCH=0, text difference is not treated as failure")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    echo "[scenario2] test finished with failure (rc=${RC})" >&2
    exit ${RC}
fi

echo "============================================================"
echo "[scenario2] PASS: decode degraded by one NPU;"
echo "            prefill remained DP${DP_SIZE}TP${TP_SIZE} unchanged."
echo "  baseline : ${PRE_OUTPUT}"
echo "  degraded : ${POST_OUTPUT}"
echo "  logs     : ${SCENARIO_LOG_DIR}"
echo "============================================================"
exit 0
