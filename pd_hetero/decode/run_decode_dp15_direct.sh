#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 直接以 DP15TP1（缩容后计算拓扑）启动 decode 服务并连续探测，
# 跳过 DP16 启动 + 故障触发 + 全量 worker 重启 + 二次权重加载。
#
# 与真实缩容后状态的等价性说明：
#   - 使用 NPU 0..14，与 DP16TP1 -> DP15TP1 缩容后的存活拓扑一致；
#   - data_parallel_size=15 / EP=15，256 专家按 18/17 切分，
#     MoE 走 A3 ALLGATHER 回退路径，与缩容后 worker 一致；
#   - 一次性完成模型加载、KV cache 分配与 FULL 图捕获，
#     避免真实缩容流程中的二次加载。
#   - 不构造 zero_interrupt_config / DP16->DP15 控制面状态，
#     因此只用于定位 DP15 稳态推理问题；控制面/恢复问题仍需
#     run_decode_fault_alone.sh / run_decode_recover_alone.sh。
#
# 使用方式（decode 节点执行）：
#   LOCAL_IP=7.246.78.75 nohup bash run_decode_dp15_direct.sh \
#     > /opt/its/z30055003/logs/decode_dp15_direct/run.log 2>&1 &
#
# 环境变量：
#   WORK_ROOT / MODEL_PATH / LOCAL_IP / NIC /
#   DIRECT_DP_SIZE / DIRECT_TP_SIZE /
#   DECODE_VLLM_PORT_START / DECODE_ITS_PORT_START / DECODE_DEVICE_START /
#   DECODE_LOG_DIR / TEST_LOG_DIR /
#   START_DECODE / STOP_EXISTING / PROBE / PROBE_RANK / N_REPEATS /
#   MAX_TOKENS / PROMPT / REQUEST_TEMPERATURE / REQUEST_SEED / PYTHON_BIN
#
# 常用快捷方式：
#   1) 只探测已启动的 DP15 服务，不拉起服务：
#      START_DECODE=0 PROBE=1 N_REPEATS=5 bash run_decode_dp15_direct.sh
#   2) 拉起前先清理本脚本端口范围内的旧服务：
#      STOP_EXISTING=1 bash run_decode_dp15_direct.sh
#   3) 关闭 token/DP 元数据诊断，减少日志量：
#      VLLM_ITS_DUMP_SAMPLED_TOKENS=0 VLLM_ITS_DUMP_DP_META_EVERY=0 \
#      bash run_decode_dp15_direct.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"
DIRECT_DP_SIZE="${DIRECT_DP_SIZE:-15}"
DIRECT_TP_SIZE="${DIRECT_TP_SIZE:-1}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START:-18001}"
DECODE_DEVICE_START="${DECODE_DEVICE_START:-0}"
DECODE_DP_RPC_PORT="${DECODE_DP_RPC_PORT:-22345}"
DECODE_KV_PORT="${DECODE_KV_PORT:-36200}"
DECODE_LOG_DIR="${DECODE_LOG_DIR:-${WORK_ROOT}/logs/decode_dp15_direct}"
TEST_LOG_DIR="${TEST_LOG_DIR:-${WORK_ROOT}/logs/decode_dp15_direct}"
START_DECODE="${START_DECODE:-1}"
STOP_EXISTING="${STOP_EXISTING:-0}"
PROBE="${PROBE:-1}"
PROBE_RANK="${PROBE_RANK:-0}"
N_REPEATS="${N_REPEATS:-5}"
MAX_TOKENS="${MAX_TOKENS:-64}"
PROMPT="${PROMPT:-请介绍一下量子计算的原理：}"
REQUEST_TEMPERATURE="${REQUEST_TEMPERATURE:-0.0}"
REQUEST_SEED="${REQUEST_SEED:-1024}"
CURL_TIMEOUT="${CURL_TIMEOUT:-180}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"

mkdir -p "${DECODE_LOG_DIR}" "${TEST_LOG_DIR}"

export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DECODE_VLLM_PORT_START DECODE_ITS_PORT_START DECODE_LOG_DIR
export PYTHON_BIN
export VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"
# 默认打开逐 step 采样与 DP 元数据诊断，卡死/分叉时日志可直接定位。
export VLLM_ITS_DUMP_SAMPLED_TOKENS="${VLLM_ITS_DUMP_SAMPLED_TOKENS:-1}"
export VLLM_ITS_DUMP_DP_META_EVERY="${VLLM_ITS_DUMP_DP_META_EVERY:-1}"

echo "============================================================"
echo "[decode-dp15-direct] local ip : ${LOCAL_IP}"
echo "[decode-dp15-direct] topology : DP${DIRECT_DP_SIZE}TP${DIRECT_TP_SIZE} (direct start)"
echo "[decode-dp15-direct] devices  : NPU ${DECODE_DEVICE_START}..$((DECODE_DEVICE_START + DIRECT_DP_SIZE - 1))"
echo "[decode-dp15-direct] vllm ports: ${DECODE_VLLM_PORT_START}..$((DECODE_VLLM_PORT_START + DIRECT_DP_SIZE - 1))"
echo "[decode-dp15-direct] ITS ports : ${DECODE_ITS_PORT_START}..$((DECODE_ITS_PORT_START + DIRECT_DP_SIZE - 1))"
echo "[decode-dp15-direct] log dir   : ${DECODE_LOG_DIR}"
echo "[decode-dp15-direct] probe     : dp${PROBE_RANK}, repeats=${N_REPEATS}"
echo "[decode-dp15-direct] diag      : DUMP_SAMPLED_TOKENS=${VLLM_ITS_DUMP_SAMPLED_TOKENS}, DUMP_DP_META_EVERY=${VLLM_ITS_DUMP_DP_META_EVERY}"
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
    echo "[decode-dp15-direct] wait ${label} port=${port}"
    for _attempt in $(seq 1 $((timeout / 2))); do
        if check_http "${port}"; then
            echo "[decode-dp15-direct] ${label} is ready"
            return 0
        fi
        sleep 2
    done
    echo "[decode-dp15-direct][ERROR] timeout waiting for ${label} port=${port}" >&2
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

stop_existing_dp15() {
    # 只清理本脚本 DP15 端口范围内的 vLLM API server。
    # API server 退出会联动 EngineCore/worker 退出（parent exit 处理）。
    echo "[decode-dp15-direct] stopping existing vllm api_server processes ..."
    for ((rank = 0; rank < DIRECT_DP_SIZE; rank++)); do
        local vllm_port=$((DECODE_VLLM_PORT_START + rank))
        pkill -f "vllm.entrypoints.openai.api_server.*--port ${vllm_port}" \
            >/dev/null 2>&1 || true
    done
    # 等待端口释放，避免新服务 bind 失败。
    for _attempt in $(seq 1 30); do
        if ! all_http_ready "${DIRECT_DP_SIZE}"; then
            break
        fi
        sleep 2
    done
    if all_http_ready "${DIRECT_DP_SIZE}"; then
        echo "[decode-dp15-direct][ERROR] existing vllm services still occupy the target ports; stop them manually or use a different port range" >&2
        return 1
    fi
    echo "[decode-dp15-direct] existing service cleanup finished"
}

# ------------------------------------------------------------------
# 1. 启动 / 复用 DP15TP1 服务。
# ------------------------------------------------------------------
if [[ "${START_DECODE}" == "1" ]]; then
    if all_http_ready "${DIRECT_DP_SIZE}"; then
        echo "[decode-dp15-direct] ${DIRECT_DP_SIZE} decode engines already healthy, skip launch"
    else
        if [[ "${STOP_EXISTING}" == "1" ]]; then
            stop_existing_dp15
        fi
        echo "[decode-dp15-direct] launching DP${DIRECT_DP_SIZE}TP${DIRECT_TP_SIZE} decode directly ..."
        nohup env \
            DECODE_DP_SIZE="${DIRECT_DP_SIZE}" \
            DECODE_TP_SIZE="${DIRECT_TP_SIZE}" \
            DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START}" \
            DECODE_ITS_PORT_START="${DECODE_ITS_PORT_START}" \
            DECODE_DEVICE_START="${DECODE_DEVICE_START}" \
            DECODE_DP_RPC_PORT="${DECODE_DP_RPC_PORT}" \
            DECODE_KV_PORT="${DECODE_KV_PORT}" \
            DECODE_LOG_DIR="${DECODE_LOG_DIR}" \
            bash "${SCRIPT_DIR}/launch_decode_pd.sh" \
            > "${TEST_LOG_DIR}/launch_direct.log" 2>&1 &
    fi
fi

for ((rank = 0; rank < DIRECT_DP_SIZE; rank++)); do
    wait_http "decode dp${rank} (direct DP${DIRECT_DP_SIZE})" \
        "$((DECODE_VLLM_PORT_START + rank))" "${STARTUP_TIMEOUT}" || exit 1
done
echo "[decode-dp15-direct] DP${DIRECT_DP_SIZE}TP${DIRECT_TP_SIZE} service ready"

# ------------------------------------------------------------------
# 2. 连续探测同一请求，判断是否卡死/分叉。
# ------------------------------------------------------------------
if [[ "${PROBE}" != "1" ]]; then
    echo "[decode-dp15-direct] PROBE=0, service left running; use run_decode_probe.sh manually."
    exit 0
fi

if (( PROBE_RANK < 0 || PROBE_RANK >= DIRECT_DP_SIZE )); then
    echo "[decode-dp15-direct][ERROR] PROBE_RANK=${PROBE_RANK} must be in [0, ${DIRECT_DP_SIZE})" >&2
    exit 1
fi

PROBE_PORT=$((DECODE_VLLM_PORT_START + PROBE_RANK))
echo "[decode-dp15-direct] probing decode dp${PROBE_RANK} port=${PROBE_PORT}"

for _i in $(seq 1 "${N_REPEATS}"); do
    _out="${TEST_LOG_DIR}/probe_${_i}.json"
    echo "===== repeat ${_i} $(date '+%F %T.%3N') ====="
    curl -sS --max-time "${CURL_TIMEOUT}" \
        "http://127.0.0.1:${PROBE_PORT}/v1/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"dsv4\",\"prompt\":\"${PROMPT}\",\"max_tokens\":${MAX_TOKENS},\"temperature\":${REQUEST_TEMPERATURE},\"seed\":${REQUEST_SEED}}" \
        -o "${_out}" || {
            _rc=$?
            echo "[decode-dp15-direct][ERROR] repeat ${_i} curl failed/timeout rc=${_rc}"
            exit ${_rc}
        }
    echo "[decode-dp15-direct] repeat ${_i} response saved: ${_out}"
done

# ------------------------------------------------------------------
# 3. 解析并对比多次输出。
# ------------------------------------------------------------------
"${PYTHON_BIN}" - "${TEST_LOG_DIR}" "${N_REPEATS}" <<'PY'
import json
import sys

test_dir, n = sys.argv[1], int(sys.argv[2])
texts = []
for i in range(1, n + 1):
    path = f"{test_dir}/probe_{i}.json"
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    text = ((data.get("choices") or [{}])[0].get("text") or "")
    reason = ((data.get("choices") or [{}])[0].get("finish_reason"))
    stop = ((data.get("choices") or [{}])[0].get("stop_reason"))
    usage = data.get("usage") or {}
    texts.append(text)
    print(f"REPEAT_{i}_TEXT={text!r}")
    print(f"REPEAT_{i}_FINISH={reason} STOP={stop} "
          f"COMPLETION_TOKENS={usage.get('completion_tokens')}")

identical = all(t == texts[0] for t in texts)
print(f"ALL_IDENTICAL={identical}")
if not texts or not any(texts):
    print("[FAIL] empty response")
    sys.exit(1)
if not identical:
    print("[FAIL] DP15 direct responses differ across repeats")
    sys.exit(2)
print("[PASS] DP15 direct repeated requests are identical")
PY
RC=$?
if [[ ${RC} -ne 0 ]]; then
    echo "[decode-dp15-direct] probe comparison failed (rc=${RC})" >&2
    echo "[decode-dp15-direct] logs: ${DECODE_LOG_DIR}/dp*.log" >&2
    exit ${RC}
fi

echo "============================================================"
echo "[decode-dp15-direct] PASS: direct DP${DIRECT_DP_SIZE}TP${DIRECT_TP_SIZE} inference is deterministic."
echo "  probe dir : ${TEST_LOG_DIR}"
echo "  engine logs: ${DECODE_LOG_DIR}"
echo "============================================================"
exit 0
