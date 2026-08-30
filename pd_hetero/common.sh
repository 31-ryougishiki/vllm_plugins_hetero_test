#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# pd_hetero 编排脚本公共函数库，供 run_scenario1/2/3.sh source 使用。
# 本文件只提供通用工具，不包含任何场景拓扑/触发逻辑。
#
# 使用顺序：先定义场景变量 -> 设置 TAG_PREFIX -> source common.sh -> 调用函数。
#
# 依赖调用方已定义的变量：
#   SCENARIO_LOG_DIR / PROXY_URL / PROMPT / MAX_TOKENS /
#   REQUEST_TEMPERATURE / REQUEST_SEED /
#   WARMUP_RETRIES / WARMUP_INTERVAL / WARMUP_REQUESTS
#   （run_warmup 显式传入 needed 时不需要 WARMUP_REQUESTS）
# 可选变量：
#   TAG_PREFIX  日志前缀，如 "[scenario1]"，默认 "[pd]"
#   PYTHON_BIN  默认 python3
#   PROXY_API_HOST  代理管理接口地址，默认 127.0.0.1

COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_ROOT_DIR="$(cd "${COMMON_SCRIPT_DIR}/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-python3}"
TAG_PREFIX="${TAG_PREFIX:-[pd]}"

log() { echo "${TAG_PREFIX} $*"; }
log_err() { echo "${TAG_PREFIX}[ERROR] $*" >&2; }
log_warn() { echo "${TAG_PREFIX}[WARN] $*" >&2; }

# 检查一个 HTTP 端点是否为 200。用法：check_http <host> <port> [path]
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

# 轮询等待 HTTP 端点就绪。用法：wait_http <label> <host> <port> [path] [timeout]
wait_http() {
    local label="$1"
    local host="$2"
    local port="$3"
    local path="${4:-/health}"
    local timeout="${5:-600}"
    log "wait ${label} http://${host}:${port}${path} (${timeout}s)"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if check_http "${host}" "${port}" "${path}"; then
            log "${label} is ready"
            return 0
        fi
        sleep 2
    done
    log_err "timeout waiting for ${label} http://${host}:${port}${path}"
    return 1
}

# 轮询等待日志中出现 marker。用法：wait_log_marker <label> <log_file> <marker> [timeout]
wait_log_marker() {
    local label="$1"
    local log_file="$2"
    local marker="$3"
    local timeout="${4:-600}"
    log "wait ${label} marker in ${log_file}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if grep -q "${marker}" "${log_file}" 2>/dev/null; then
            log "${label}: found '${marker}'"
            return 0
        fi
        sleep 2
    done
    log_err "timeout waiting for '${marker}' in ${log_file}"
    return 1
}

# 检查从 port_start 开始的 count 个端口是否全部就绪。
# 用法：all_http_ready <host> <port_start> <count> [path]
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

# PD 链路预热：连续发短请求，吸收首次 recompute，并覆盖全部 active decoder。
# 用法：run_warmup <label> [needed]（needed 默认取 WARMUP_REQUESTS）
run_warmup() {
    local label="$1"
    local needed="${2:-${WARMUP_REQUESTS:-1}}"
    local log_file="${SCENARIO_LOG_DIR}/${label}_warmup.log"
    local successes=0
    local max_attempts=$((needed + ${WARMUP_RETRIES:-30}))
    log "${label}: warming up PD chain "
    log "  (need ${needed} successful requests to cover all active decoders)"
    for attempt in $(seq 1 "${max_attempts}"); do
        if "${PYTHON_BIN}" "${COMMON_SCRIPT_DIR}/send_pd_request.py" \
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
                log "${label}: warmup attempt=${attempt} still recomputed"
                sleep "${WARMUP_INTERVAL:-10}"
                continue
            fi
            successes=$((successes + 1))
            log "${label}: warmup ${successes}/${needed} ${finish}"
            if (( successes >= needed )); then
                log "${label}: PD chain warmup completed"
                return 0
            fi
        else
            log "${label}: warmup attempt=${attempt} failed"
            sleep "${WARMUP_INTERVAL:-10}"
        fi
    done
    log_err "${label}: PD chain did not become ready "
    log_err "  (only ${successes}/${needed} successful warmups)"
    tail -n 20 "${log_file}" >&2 || true
    return 1
}

# 经代理发一次正式请求并保存 JSON。用法：send_request <label> <output_path>
send_request() {
    local label="$1"
    local output="$2"
    local log_file="${SCENARIO_LOG_DIR}/${label}_request.log"
    log "${label} request ..."
    if ! "${PYTHON_BIN}" "${COMMON_SCRIPT_DIR}/send_pd_request.py" \
            --url "${PROXY_URL}" \
            --model dsv4 \
            --prompt "${PROMPT}" \
            --max-tokens "${MAX_TOKENS}" \
            --temperature "${REQUEST_TEMPERATURE}" \
            --seed "${REQUEST_SEED}" \
            --output "${output}" \
            --timeout 600 \
            > "${log_file}" 2>&1; then
        log_err "${label} request failed"
        cat "${log_file}" >&2
        return 1
    fi
    grep "RESULT_TEXT=" "${log_file}" || true
}

# 比较前后两次请求的 choices[0].text。
# 用法：compare_outputs <pre_json> <post_json> <require_match(0|1)> <fail_msg> <pass_msg>
# 基线文件缺失时自动降级为“只校验非空”（与原场景 3 行为一致）。
compare_outputs() {
    local pre_path="$1"
    local post_path="$2"
    local require_match="$3"
    local fail_msg="$4"
    local pass_msg="$5"
    if [[ "${require_match}" == "1" && ! -f "${pre_path}" ]]; then
        log_warn "baseline ${pre_path} not found; only checking non-empty output"
        require_match=0
    fi
    log "comparing outputs: ${post_path} vs ${pre_path}"
    "${PYTHON_BIN}" - "${pre_path}" "${post_path}" "${require_match}" \
        "${fail_msg}" "${pass_msg}" <<'PY'
import json
import sys

pre_path, post_path, require_match, fail_msg, pass_msg = sys.argv[1:6]
require_match = require_match == "1"

post = json.load(open(post_path, encoding="utf-8"))
post_text = (post.get("choices") or [{}])[0].get("text") or ""
post_reason = (post.get("choices") or [{}])[0].get("finish_reason")
pre_text = None
pre_reason = None

if require_match:
    pre = json.load(open(pre_path, encoding="utf-8"))
    pre_text = (pre.get("choices") or [{}])[0].get("text") or ""
    pre_reason = (pre.get("choices") or [{}])[0].get("finish_reason")
    print(f"PRE_TEXT={pre_text!r}")
else:
    print("PRE_TEXT=<skipped: no baseline or match disabled>")

print(f"POST_TEXT={post_text!r}")
print(f"PRE_FINISH={pre_reason} POST_FINISH={post_reason}")
print(f"MATCH={pre_text == post_text if pre_text is not None else 'N/A'}")

if not post_text:
    print(f"[FAIL] {fail_msg}: post output is empty")
    sys.exit(1)
if require_match and pre_text is not None and pre_text != post_text:
    print(f"[FAIL] {fail_msg}")
    sys.exit(2)
if require_match:
    print(f"[PASS] {pass_msg}")
else:
    print("[WARN] REQUIRE_OUTPUT_MATCH=0, text difference is not treated as failure")
PY
}

# 代理实例管理。用法：proxy_instance <add|remove> <host> <port>
proxy_instance() {
    local action="$1"
    local host="$2"
    local port="$3"
    "${PYTHON_BIN}" "${COMMON_SCRIPT_DIR}/proxy_instance.py" \
        "${action}" "${PROXY_API_HOST:-127.0.0.1}" "${PROXY_PORT}" "${host}" "${port}"
}

# 与旧脚本同名的包装，保持调用方语义直观。
add_proxy_instance() { proxy_instance add "$@"; }
remove_proxy_instance() { proxy_instance remove "$@"; }

# 通过决策中心触发一张卡故障。用法：dc_trigger_fault <node_ip> <npu_id>
dc_trigger_fault() {
    DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}" \
        FAULT_CODE="${FAULT_CODE:-80E78000}" \
        bash "${COMMON_ROOT_DIR}/decision_center/trigger_fault.sh" "$1" "$2"
}

# 通过决策中心上报坏卡修复（可一次上报多张）。
# 用法：dc_repair_devices <node_ip>:<npu_id> [<node_ip>:<npu_id> ...]
dc_repair_devices() {
    DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}" \
        bash "${COMMON_ROOT_DIR}/decision_center/repair_devices.sh" "$@"
}

# 在 D 节点执行 trigger 脚本。用法：trigger_decode_remote <fault|recover>
# 依赖：SSH_DECODE / DECODE_TEST_DIR / DECODE_HOST / NIC / DECODE_FAULT_NPU /
#       DECODE_DP_SIZE / DECODE_ITS_PORT_START / DECODE_VLLM_PORT_START /
#       DECODE_LOG_DIR / RESTART_TIMEOUT
trigger_decode_remote() {
    local action="$1"
    local trigger_script
    case "${action}" in
        fault) trigger_script="trigger_decode_fault.sh" ;;
        recover) trigger_script="trigger_decode_recover.sh" ;;
        *) log_err "trigger_decode_remote: unknown action=${action}"; return 2 ;;
    esac
    if [[ -z "${SSH_DECODE}" ]]; then
        log_err "TRIGGER_MODE=ssh requires SSH_DECODE=root@<decode-ip>"
        return 2
    fi
    log "triggering decode ${action} via ssh ${SSH_DECODE} ..."
    ssh "${SSH_DECODE}" \
        "cd '${DECODE_TEST_DIR}' && \
         LOCAL_IP='${DECODE_HOST}' NIC='${NIC}' \
         DECODE_FAULT_NPU='${DECODE_FAULT_NPU}' \
         DECODE_DP_SIZE='${DECODE_DP_SIZE}' \
         DECODE_ITS_PORT_START='${DECODE_ITS_PORT_START}' \
         DECODE_VLLM_PORT_START='${DECODE_VLLM_PORT_START}' \
         DECODE_LOG_DIR='${DECODE_LOG_DIR}' \
         RESTART_TIMEOUT='${RESTART_TIMEOUT}' \
         bash decode/${trigger_script}"
}

# 与 P 同节点时本地执行 trigger 脚本。用法：trigger_decode_local <fault|recover>
trigger_decode_local() {
    local action="$1"
    local trigger_script
    case "${action}" in
        fault) trigger_script="trigger_decode_fault.sh" ;;
        recover) trigger_script="trigger_decode_recover.sh" ;;
        *) log_err "trigger_decode_local: unknown action=${action}"; return 2 ;;
    esac
    log "triggering decode ${action} locally ..."
    LOCAL_IP="${DECODE_HOST}" \
        DECODE_FAULT_NPU="${DECODE_FAULT_NPU}" \
        DECODE_DP_SIZE="${DECODE_DP_SIZE}" \
        DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START}" \
        DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
        DECODE_LOG_DIR="${DECODE_LOG_DIR}" \
        RESTART_TIMEOUT="${RESTART_TIMEOUT}" \
        bash "${COMMON_SCRIPT_DIR}/decode/${trigger_script}"
}
