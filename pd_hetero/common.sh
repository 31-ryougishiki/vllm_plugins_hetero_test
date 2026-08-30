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

# 检查本节点已运行的 vllm api_server 进程是否使用了决策中心注册所需的
# VLLM_ITS_DECISION_CENTER_URL / VLLM_SERVICE_ID。dc 模式下只看 /health
# 无法证明 executor 已注册，/proc/<pid>/environ 至少能证明启动环境正确；
# 读不到环境时 fail-closed，调用方可显式 ASSUME_DC_REGISTERED=1。
# 用法：dc_registration_env_ok <decision_center_url> <service_id> <min_pids>
dc_registration_env_ok() {
    local expected_url="$1"
    local expected_service="$2"
    local min_pids="$3"
    "${PYTHON_BIN}" - "${expected_url}" "${expected_service}" "${min_pids}" <<'PY'
import os
import sys

expected_url, expected_service, min_pids = sys.argv[1], sys.argv[2], int(sys.argv[3])
matched = 0
readable = 0
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    pid_dir = f"/proc/{name}"
    try:
        with open(f"{pid_dir}/cmdline", "rb") as f:
            cmdline = f.read().replace(b"\x00", b" ").decode(
                "utf-8", errors="replace"
            )
        if "vllm.entrypoints.openai.api_server" not in cmdline:
            continue
        with open(f"{pid_dir}/environ", "rb") as f:
            raw = f.read()
        readable += 1
    except (OSError, PermissionError):
        continue
    env = {}
    for item in raw.split(b"\x00"):
        if not item:
            continue
        key, _, value = item.partition(b"=")
        env[key.decode(errors="replace")] = value.decode(errors="replace")
    if (
        env.get("VLLM_ITS_DECISION_CENTER_URL", "").rstrip("/") == expected_url.rstrip("/")
        and env.get("VLLM_SERVICE_ID") == expected_service
    ):
        matched += 1

print(
    f"{sys.argv[0]}: dc registration env check matched={matched} "
    f"readable={readable} min_pids={min_pids}"
)
sys.exit(0 if matched >= min_pids else 1)
PY
}

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

# 读取 executor ITS /status 中的一个字段。失败时返回空串。
# 用法：its_status_field <host> <port> <field>
its_status_field() {
    local host="$1"
    local port="$2"
    local field="$3"
    "${PYTHON_BIN}" - "${host}" "${port}" "${field}" <<'PY'
import json
import sys
import urllib.request

host, port, field = sys.argv[1], int(sys.argv[2]), sys.argv[3]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(f"http://{host}:{port}/api/v1/executor/status",
                     timeout=5) as resp:
        if resp.status != 200:
            sys.exit(0)
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
except Exception:
    sys.exit(0)

value = data.get(field)
if value is None:
    sys.exit(0)
print(value)
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

# 计算日志中一组 marker 的当前总行数。
# 用法：log_marker_count <log_file> <marker> [alt_marker...]
log_marker_count() {
    local log_file="$1"
    local marker="$2"
    shift 2
    local -a grep_args=("-c" "-e" "${marker}")
    local alt
    for alt in "$@"; do
        [[ -n "${alt}" ]] && grep_args+=("-e" "${alt}")
    done
    local count
    count="$(grep "${grep_args[@]}" "${log_file}" 2>/dev/null || true)"
    count="${count//[^0-9]/}"
    [[ -n "${count}" ]] || count=0
    echo "${count}"
}

# 轮询等待日志中出现【新的】marker。
# 用法：wait_log_marker <label> <log_file> <marker> [timeout] [baseline] [alt_marker...]
# 以 baseline 为比较起点，只有计数增长才算等待成功。省略 baseline 时用
# 调用时刻的计数做基线（保留旧行为）。重复下发同一份策略时 executor 幂等
# 短路，日志会打印 "skipping redundant worker restart" 而不是再次重启；
# alt_marker 用于把该幂等日志也视为等待成功。
#
# 注意：幂等短路日志可能在调用本函数之前就已经写入，因此需要"等待策略
# 下发之前"的计数时，调用方必须在触发前用 log_marker_count 快照，并把该
# 值作为 baseline 传入；否则策略执行快于第一次计数时会误超时。
wait_log_marker() {
    local label="$1"
    local log_file="$2"
    local marker="$3"
    local timeout="${4:-600}"
    shift 4
    # 兼容两种调用：旧式 [alt_marker...]；新式 [baseline] [alt_marker...]。
    # 第 5 个参数是纯数字（或空串）时按 baseline 解析。
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
    log "wait ${label} new marker in ${log_file} (baseline count=${before})"
    for _attempt in $(seq 1 $((timeout / 2))); do
        local now
        now="$(grep "${grep_args[@]}" "${log_file}" 2>/dev/null || true)"
        now="${now//[^0-9]/}"
        [[ -n "${now}" ]] || now=0
        if [[ "${now}" -gt "${before}" ]]; then
            log "${label}: found new '${marker}' (${before} -> ${now})"
            return 0
        fi
        sleep 2
    done
    log_err "timeout waiting for new '${marker}' in ${log_file} (baseline count=${before})"
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
            # vllm-ascend 的 recompute 信号在 stop_reason 字段（finish_reason
            # 仍为 stop），只查 FINISH_REASON 永远匹配不到 "recomputed"。
            finish="$(grep '^FINISH_REASON=' "${log_file}" | tail -n 1 || true)"
            stop_reason="$(grep '^STOP_REASON=' "${log_file}" | tail -n 1 || true)"
            if [[ "${finish}" == "FINISH_REASON=recomputed" \
                  || "${stop_reason}" == "STOP_REASON=recomputed" ]]; then
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
# require_match=1 时基线必须存在；text 必须相同，且 stop_reason 不能是
# recomputed、pre/post 的 finish_reason 不能漂移，避免“文本碰巧相同”掩盖
# 未恢复的 KV 链路。
compare_outputs() {
    local pre_path="$1"
    local post_path="$2"
    local require_match="$3"
    local fail_msg="$4"
    local pass_msg="$5"
    if [[ "${require_match}" == "1" && ! -f "${pre_path}" ]]; then
        log_err "baseline ${pre_path} not found; refusing to report PASS " \
            "for a text-match scenario without a baseline"
        return 2
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
post_stop = (post.get("choices") or [{}])[0].get("stop_reason")
pre_text = None
pre_reason = None
pre_stop = None

if require_match:
    pre = json.load(open(pre_path, encoding="utf-8"))
    pre_text = (pre.get("choices") or [{}])[0].get("text") or ""
    pre_reason = (pre.get("choices") or [{}])[0].get("finish_reason")
    pre_stop = (pre.get("choices") or [{}])[0].get("stop_reason")
    print(f"PRE_TEXT={pre_text!r}")
else:
    print("PRE_TEXT=<skipped: match disabled>")

print(f"POST_TEXT={post_text!r}")
print(f"PRE_FINISH={pre_reason} PRE_STOP={pre_stop} "
      f"POST_FINISH={post_reason} POST_STOP={post_stop}")
print(f"MATCH={pre_text == post_text if pre_text is not None else 'N/A'}")

if not post_text:
    print(f"[FAIL] {fail_msg}: post output is empty")
    sys.exit(1)
if require_match and pre_text is not None and pre_text != post_text:
    print(f"[FAIL] {fail_msg}")
    sys.exit(2)
if require_match:
    # 文本相同但 stop_reason 仍是 recompute 时说明 KV 链路没有真正恢复
    # （warmup 未生效）；pre/post finish_reason 不同也说明行为发生漂移。
    # 两者同时为 length 只代表按 max_tokens 截断，不判失败。
    for label, stop in (("PRE", pre_stop), ("POST", post_stop)):
        if stop == "recomputed":
            print(f"[FAIL] {fail_msg}: {label} stop_reason=recomputed")
            sys.exit(2)
    if pre_reason != post_reason:
        print(f"[FAIL] {fail_msg}: finish_reason changed "
              f"{pre_reason} -> {post_reason}")
        sys.exit(2)
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
         PYTHON_BIN='${PYTHON_BIN}' NUM_NPUS='${NUM_NPUS:-16}' \
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
        PYTHON_BIN="${PYTHON_BIN}" \
        NUM_NPUS="${NUM_NPUS:-16}" \
        DECODE_FAULT_NPU="${DECODE_FAULT_NPU}" \
        DECODE_DP_SIZE="${DECODE_DP_SIZE}" \
        DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START}" \
        DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
        DECODE_LOG_DIR="${DECODE_LOG_DIR}" \
        RESTART_TIMEOUT="${RESTART_TIMEOUT}" \
        bash "${COMMON_SCRIPT_DIR}/decode/${trigger_script}"
}
