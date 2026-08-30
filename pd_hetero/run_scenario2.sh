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
#   dc    通过决策中心 /test/trigger_fault 触发
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
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
REQUIRE_OUTPUT_MATCH="${REQUIRE_OUTPUT_MATCH:-1}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
WARMUP_RETRIES="${WARMUP_RETRIES:-30}"
WARMUP_INTERVAL="${WARMUP_INTERVAL:-10}"
# warmup 数量在基线前设为 DECODE_DP_SIZE，D 降级后设为存活 decoder 数。
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
ACTIVE_DECODE_COUNT="${NEW_DECODE_DP}"

export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DP_SIZE TP_SIZE NUM_NPUS VLLM_PORT_START ITS_HTTP_PORT_START
export DECODE_HOST DECODE_DP_SIZE DECODE_VLLM_PORT_START
export PROXY_HOST PROXY_PORT PYTHON_BIN

mkdir -p "${SCENARIO_LOG_DIR}"

TAG_PREFIX="[scenario2]"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo "============================================================"
echo "[scenario2] prefill node: ${LOCAL_IP}  (DP4TP4 unchanged)"
echo "[scenario2] decode node : ${DECODE_HOST} (DP${DECODE_DP_SIZE}TP1 -> DP${NEW_DECODE_DP}TP1)"
echo "[scenario2] fault npu   : ${DECODE_FAULT_NPU}"
echo "[scenario2] trigger mode: ${TRIGGER_MODE}"
echo "[scenario2] proxy       : ${PROXY_URL}"
echo "[scenario2] output dir  : ${SCENARIO_LOG_DIR}"
echo "============================================================"

# P 端“已重启”日志计数：后面用于证明 P 保持未变。
prefill_restart_marker_count() {
    local dp_rank="$1"
    grep -c "restarting workers of EVERY DP instance" \
        "${PREFILL_LOG_DIR}/dp${dp_rank}.log" 2>/dev/null || echo 0
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
send_request "baseline" "${PRE_OUTPUT}" || exit 1

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
        if ! trigger_decode_remote fault \
                | tee "${SCENARIO_LOG_DIR}/trigger_decode.log"; then
            echo "[scenario2][ERROR] remote decode trigger failed" >&2
            exit 1
        fi
        ;;
    local)
        if ! trigger_decode_local fault \
                | tee "${SCENARIO_LOG_DIR}/trigger_decode.log"; then
            echo "[scenario2][ERROR] local decode trigger failed" >&2
            exit 1
        fi
        ;;
    skip)
        echo "[scenario2] TRIGGER_MODE=skip: assuming decode fault was already triggered"
        ;;
    dc)
        echo "[scenario2] trigger mode=decision_center url=${DECISION_CENTER_URL}"
        if dc_trigger_fault "${DECODE_HOST}" "${DECODE_FAULT_NPU}" \
                | tee "${SCENARIO_LOG_DIR}/trigger_dc.log"; then
            echo "[scenario2] decision center accepted decode fault"
        else
            echo "[scenario2][ERROR] decision center trigger_fault failed" >&2
            exit 1
        fi
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

# 决策中心可能因专家数整除等约束选择不等于 DP15 的合法拓扑。dc 模式
# 下以实际 /health 存活数为准，并把所有不可用的 decoder 都从代理摘除。
if [[ "${TRIGGER_MODE}" == "dc" ]]; then
    echo "[scenario2] discovering active decode engines after decision-center degrade ..."
    ACTIVE_DECODE_COUNT=0
    for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
        if check_http "${DECODE_HOST}" "$((DECODE_VLLM_PORT_START + dp_rank))" /health; then
            ACTIVE_DECODE_COUNT=$((ACTIVE_DECODE_COUNT + 1))
            echo "[scenario2] decode dp${dp_rank}: healthy"
        else
            echo "[scenario2] decode dp${dp_rank}: unavailable after degrade"
        fi
    done
    if (( ACTIVE_DECODE_COUNT <= 0 )); then
        echo "[scenario2][ERROR] no decode engine survived decision-center degrade" >&2
        exit 1
    fi
    echo "[scenario2] decision-center degraded decode: ${ACTIVE_DECODE_COUNT}/${DECODE_DP_SIZE} active"
fi

# ------------------------------------------------------------------
# 6. 确认 P 端仍未重启、D 端剩余 engine 健康。
# ------------------------------------------------------------------
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    wait_http "prefill dp${dp_rank} (unchanged)" "127.0.0.1" \
        "$((VLLM_PORT_START + dp_rank))" /health 120 || exit 1
done
if [[ "${TRIGGER_MODE}" == "dc" ]]; then
    echo "[scenario2] using discovered active count: ${ACTIVE_DECODE_COUNT}"
else
    ACTIVE_DECODE_COUNT="${NEW_DECODE_DP}"
    for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
        if (( dp_rank == DECODE_FAULT_NPU )); then
            continue
        fi
        wait_http "decode dp${dp_rank} (after degrade)" "${DECODE_HOST}" \
            "$((DECODE_VLLM_PORT_START + dp_rank))" /health "${RESTART_TIMEOUT}" || exit 1
    done
fi
echo "[scenario2] decode remaining engines: ${ACTIVE_DECODE_COUNT}/${DECODE_DP_SIZE} healthy (fault rank ${DECODE_FAULT_NPU} excluded)"

# ------------------------------------------------------------------
# 7. 从代理摘除故障 decoder，避免后续请求轮询到空转 executor。
# ------------------------------------------------------------------
FAULT_DECODE_PORT=$((DECODE_VLLM_PORT_START + DECODE_FAULT_NPU))
echo "[scenario2] removing fault decoder ${DECODE_HOST}:${FAULT_DECODE_PORT} from proxy ..."
remove_proxy_instance "${DECODE_HOST}" "${FAULT_DECODE_PORT}" \
    | tee -a "${SCENARIO_LOG_DIR}/proxy_remove.log"

if [[ "${TRIGGER_MODE}" == "dc" ]]; then
    # 决策中心可能额外关闭若干 decoder（例如为满足 expert_num 整除）。
    # 所有 /health 不可用的 decoder 都要摘除，避免代理轮询到空转 engine。
    for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
        if (( dp_rank == DECODE_FAULT_NPU )); then
            continue
        fi
        if ! check_http "${DECODE_HOST}" "$((DECODE_VLLM_PORT_START + dp_rank))" /health; then
            echo "[scenario2] removing unavailable decoder dp${dp_rank} from proxy ..."
            remove_proxy_instance "${DECODE_HOST}" \
                "$((DECODE_VLLM_PORT_START + dp_rank))" \
                | tee -a "${SCENARIO_LOG_DIR}/proxy_remove.log"
        fi
    done
fi

# ------------------------------------------------------------------
# 8. D 降级后的复测请求。
# ------------------------------------------------------------------
WARMUP_REQUESTS="${ACTIVE_DECODE_COUNT}"
run_warmup "post_degrade" || exit 1
send_request "post_degrade" "${POST_OUTPUT}" || exit 1

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
compare_outputs "${PRE_OUTPUT}" "${POST_OUTPUT}" "${REQUIRE_OUTPUT_MATCH}" \
    "post-degrade output differs from baseline" \
    "decode DP16TP1 -> DP15TP1 output is identical to baseline"
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
