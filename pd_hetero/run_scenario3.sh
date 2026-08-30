#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 3：RECOVER，把场景 1 和场景 2 的降级拓扑恢复回对称拓扑。
#
# 前置状态（分别由场景 1 / 场景 2 制造）：
#   - prefill 节点：DP4TP(3,4,4,4) 异构运行；
#   - decode 节点：DP15TP1 运行，executor 15 处于 Idle mode；
#   - PD 代理：已摘除故障 decoder 15。
#
# 脚本默认执行 both：
#   1. P RECOVER  DP4TP(3,4,4,4) -> DP4TP4（对称）；
#   2. D RECOVER  DP15TP1 -> DP16TP1；
#   3. 把恢复的 decoder 加回代理；
#   4. 全链路 warmup 后发请求，与降级前基线逐字对比。
#
# 使用方式（prefill 节点）：
#   SSH_DECODE="root@7.246.78.76" DECODE_HOST=7.246.78.76 \
#   nohup bash run_scenario3.sh \
#     > /opt/its/z30055003/logs/pd_scenario3/run.log 2>&1 &
#
# RECOVER_TARGET 控制恢复范围：
#   both（默认） / prefill（只恢复场景1）/ decode（只恢复场景2）。
# D 端触发方式 TRIGGER_MODE 与场景 2 相同：ssh / local / dc。
#
# 关键环境变量：
#   DECODE_HOST / SSH_DECODE / RECOVER_TARGET / TRIGGER_MODE /
#   BASELINE_OUTPUT / REQUIRE_OUTPUT_MATCH / 以及场景1/2 的端口路径变量。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
MODEL_PATH="${MODEL_PATH:-/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
NIC="${NIC:-eth2}"

# P 端。
DP_SIZE="${DP_SIZE:-4}"
TP_SIZE="${TP_SIZE:-4}"
NUM_NPUS="${NUM_NPUS:-16}"
VLLM_PORT_START="${VLLM_PORT_START:-9000}"
ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START:-8001}"
PREFILL_LOG_DIR="${PREFILL_LOG_DIR:-${WORK_ROOT}/logs/prefill}"

# D 端。
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
RECOVER_TARGET="${RECOVER_TARGET:-both}"
TRIGGER_MODE="${TRIGGER_MODE:-ssh}"
SSH_DECODE="${SSH_DECODE:-}"
DECISION_CENTER_URL="${DECISION_CENTER_URL:-http://7.246.78.79:8088}"
FAULT_NPU="${FAULT_NPU:-3}"
FAULT_NODE_IP="${FAULT_NODE_IP:-${LOCAL_IP}}"
REQUIRE_OUTPUT_MATCH="${REQUIRE_OUTPUT_MATCH:-1}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-900}"
WARMUP_RETRIES="${WARMUP_RETRIES:-30}"
WARMUP_INTERVAL="${WARMUP_INTERVAL:-10}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-${DECODE_DP_SIZE}}"
REQUEST_TEMPERATURE="${REQUEST_TEMPERATURE:-0.0}"
REQUEST_SEED="${REQUEST_SEED:-1024}"
PROMPT="${PROMPT:-请解释一下量子计算的基本原理。量子计算的基本原理是：}"
MAX_TOKENS="${MAX_TOKENS:-100}"

SCENARIO_LOG_DIR="${SCENARIO_LOG_DIR:-${WORK_ROOT}/logs/pd_scenario3}"
POST_OUTPUT="${SCENARIO_LOG_DIR}/post_recover.json"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NEW_DECODE_DP=$((DECODE_DP_SIZE - 1))

export WORK_ROOT MODEL_PATH LOCAL_IP NIC
export DP_SIZE TP_SIZE NUM_NPUS VLLM_PORT_START ITS_HTTP_PORT_START
export DECODE_HOST DECODE_DP_SIZE DECODE_VLLM_PORT_START
export PROXY_HOST PROXY_PORT PYTHON_BIN

mkdir -p "${SCENARIO_LOG_DIR}"

TAG_PREFIX="[scenario3]"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

case "${RECOVER_TARGET}" in
    both) DO_PREFILL=1; DO_DECODE=1 ;;
    prefill) DO_PREFILL=1; DO_DECODE=0 ;;
    decode) DO_PREFILL=0; DO_DECODE=1 ;;
    *)
        echo "[scenario3][ERROR] unknown RECOVER_TARGET=${RECOVER_TARGET}" >&2
        exit 1
        ;;
esac

# decision_center 模式且恢复 both 时，必须在**一次** repair/devices 里把
# 服务下所有坏卡都报给决策中心；否则第一次 repair 后决策中心发现服务仍
# 有坏卡，不会下发 RECOVER。
DC_REPAIR_SENT=0

# 默认基线按恢复范围选择：
# - both：场景1降级前的对称 P + 16 decoder；
# - prefill only：场景2降级后的对称 P + 15 decoder（恢复 P 后应一致）；
# - decode only：场景1降级后的异构 P + 16 decoder（恢复 D 后应一致）。
if [[ -z "${BASELINE_OUTPUT:-}" ]]; then
    case "${RECOVER_TARGET}" in
        both)
            PRE_OUTPUT="${WORK_ROOT}/logs/pd_scenario1/pre_hetero.json"
            ;;
        prefill)
            PRE_OUTPUT="${WORK_ROOT}/logs/pd_scenario2/post_decode_fault.json"
            ;;
        decode)
            PRE_OUTPUT="${WORK_ROOT}/logs/pd_scenario1/post_hetero.json"
            ;;
    esac
else
    PRE_OUTPUT="${BASELINE_OUTPUT}"
fi

echo "============================================================"
echo "[scenario3] prefill node: ${LOCAL_IP}"
echo "[scenario3] decode node : ${DECODE_HOST}"
echo "[scenario3] recover prefill: ${DO_PREFILL} (DP4TP(3,4,4,4) -> DP4TP4)"
echo "[scenario3] recover decode : ${DO_DECODE} (DP15TP1 -> DP16TP1)"
echo "[scenario3] fault npu   : ${DECODE_FAULT_NPU}"
echo "[scenario3] trigger mode: ${TRIGGER_MODE}"
echo "[scenario3] proxy       : ${PROXY_URL}"
echo "[scenario3] baseline    : ${PRE_OUTPUT}"
echo "[scenario3] output dir  : ${SCENARIO_LOG_DIR}"
echo "============================================================"

# ------------------------------------------------------------------
# 1. 前置状态校验：P 4 个 engine 在线（异构或对称均可），
#    D 15 个健康 + 故障 executor 空转，代理在线。
# ------------------------------------------------------------------
for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
    wait_http "prefill dp${dp_rank} (pre-recover)" "127.0.0.1" \
        "$((VLLM_PORT_START + dp_rank))" /health 300 || exit 1
done
for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    if (( dp_rank == DECODE_FAULT_NPU )); then
        # 场景 2 的结束状态：故障 executor 处于 Idle mode，其 /health 可能
        # 仍由空转 EngineCore 返回 200，也可能已经不可用，这里不做强校验；
        # DO_DECODE=1 时由远程 trigger_decode_recover.sh 确认 idle 日志。
        continue
    fi
    wait_http "decode dp${dp_rank} (pre-recover)" "${DECODE_HOST}" \
        "$((DECODE_VLLM_PORT_START + dp_rank))" /health 300 || exit 1
done
wait_http "proxy" "${PROXY_HOST}" "${PROXY_PORT}" /healthcheck 120 || exit 1
echo "[scenario3] preconditions ok: P online, D current DP=${NEW_DECODE_DP}TP1, proxy online"

# ------------------------------------------------------------------
# 2. P RECOVER：异构 DP4TP(3,4,4,4) -> 对称 DP4TP4。
# ------------------------------------------------------------------
if [[ "${DO_PREFILL}" == "1" ]]; then
    for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
        its_port=$((ITS_HTTP_PORT_START + dp_rank * TP_SIZE))
        wait_http "prefill ITS dp${dp_rank}" "127.0.0.1" "${its_port}" \
            /health 120 || exit 1
    done

    echo "[scenario3] triggering prefill RECOVER DP4TP(3,4,4,4) -> DP4TP4 ..."
    if [[ "${TRIGGER_MODE}" == "dc" ]]; then
        # dc + both 时把 P/D 坏卡合并到同一次 repair/devices 请求。
        REPAIR_ARGS=("${FAULT_NODE_IP}:${FAULT_NPU}")
        if [[ "${DO_DECODE}" == "1" ]]; then
            REPAIR_ARGS+=("${DECODE_HOST}:${DECODE_FAULT_NPU}")
        fi
        if dc_repair_devices "${REPAIR_ARGS[@]}" \
                | tee "${SCENARIO_LOG_DIR}/trigger_prefill_recover.log"; then
            DC_REPAIR_SENT=1
            echo "[scenario3] decision center accepted repair: ${FAULT_NODE_IP}/${FAULT_NPU}" \
                "$( [[ ${DO_DECODE} -eq 1 ]] && echo + ${DECODE_HOST}/${DECODE_FAULT_NPU} || true )"
        else
            echo "[scenario3][ERROR] decision center repair/devices failed" >&2
            exit 1
        fi
    else
        if ! LOCAL_IP="${LOCAL_IP}" \
                ITS_HTTP_PORT_START="${ITS_HTTP_PORT_START}" \
                DP_SIZE="${DP_SIZE}" \
                TP_SIZE="${TP_SIZE}" \
                NUM_NPUS="${NUM_NPUS}" \
                DEPLOY_TYPE=RECOVER \
                bash "${ROOT_SCRIPT_DIR}/trigger_prefill_recover.sh" \
                | tee "${SCENARIO_LOG_DIR}/trigger_prefill_recover.log"; then
            echo "[scenario3][ERROR] prefill RECOVER trigger failed" >&2
            exit 1
        fi
    fi

    echo "[scenario3] waiting for prefill symmetric recovery ..."
    for ((dp_rank = 0; dp_rank < DP_SIZE; dp_rank++)); do
        wait_http "prefill dp${dp_rank} (recovered)" "127.0.0.1" \
            "$((VLLM_PORT_START + dp_rank))" /health "${RESTART_TIMEOUT}" || exit 1
        wait_log_marker "dp${dp_rank} full-restart barrier" \
            "${PREFILL_LOG_DIR}/dp${dp_rank}.log" \
            "Full-restart barrier passed" "${RESTART_TIMEOUT}" || exit 1
        wait_log_marker "dp${dp_rank} KV connector metadata" \
            "${PREFILL_LOG_DIR}/dp${dp_rank}.log" \
            "KV connector metadata updated successfully" "${RESTART_TIMEOUT}" || exit 1
    done
    echo "[scenario3] prefill recovered to symmetric DP${DP_SIZE}TP${TP_SIZE}"

    # P 恢复后 D 的 15 个 decoder 必须仍健康（Mooncake 已按新 engine_id 恢复）。
    for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
        if (( dp_rank == DECODE_FAULT_NPU )); then
            continue
        fi
        wait_http "decode dp${dp_rank} (after P recover)" "${DECODE_HOST}" \
            "$((DECODE_VLLM_PORT_START + dp_rank))" /health 300 || exit 1
    done
fi

# ------------------------------------------------------------------
# 3. D RECOVER：DP15TP1 -> DP16TP1，并加回代理。
# ------------------------------------------------------------------
if [[ "${DO_DECODE}" == "1" ]]; then
    case "${TRIGGER_MODE}" in
        ssh)
            if ! trigger_decode_remote recover \
                    | tee "${SCENARIO_LOG_DIR}/trigger_decode_recover.log"; then
                echo "[scenario3][ERROR] remote decode RECOVER trigger failed" >&2
                exit 1
            fi
            ;;
        local)
            if ! trigger_decode_local recover \
                    | tee "${SCENARIO_LOG_DIR}/trigger_decode_recover.log"; then
                echo "[scenario3][ERROR] local decode RECOVER trigger failed" >&2
                exit 1
            fi
            ;;
        dc)
            echo "[scenario3] trigger mode=decision_center url=${DECISION_CENTER_URL}"
            if [[ "${DC_REPAIR_SENT}" == "1" ]]; then
                echo "[scenario3] decode repair already included in combined repair request, skip second POST"
            elif dc_repair_devices "${DECODE_HOST}:${DECODE_FAULT_NPU}" \
                    | tee "${SCENARIO_LOG_DIR}/trigger_decode_recover.log"; then
                echo "[scenario3] decision center accepted decode repair"
            else
                echo "[scenario3][ERROR] decision center repair/devices failed" >&2
                exit 1
            fi
            ;;
        *)
            echo "[scenario3][ERROR] unknown TRIGGER_MODE=${TRIGGER_MODE}" >&2
            exit 1
            ;;
    esac

    echo "[scenario3] waiting for decode DP${DECODE_DP_SIZE}TP1 recovery ..."
    for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
        wait_http "decode dp${dp_rank} (recovered)" "${DECODE_HOST}" \
            "$((DECODE_VLLM_PORT_START + dp_rank))" /health "${RESTART_TIMEOUT}" || exit 1
    done

    RECOVERED_DECODE_PORT=$((DECODE_VLLM_PORT_START + DECODE_FAULT_NPU))
    echo "[scenario3] adding recovered decoder ${DECODE_HOST}:${RECOVERED_DECODE_PORT} back to proxy ..."
    add_proxy_instance "${DECODE_HOST}" "${RECOVERED_DECODE_PORT}" \
        | tee -a "${SCENARIO_LOG_DIR}/proxy_add.log"

    # trigger_decode_recover.sh 已在 D 节点等待全部 16 个 executor 的
    # "Full-restart barrier passed" 与 /health 恢复，这里不再读远端日志。
    echo "[scenario3] recovered executor ${DECODE_FAULT_NPU} passed "
    echo "            full-restart barrier and rejoined decode group"
fi

# ------------------------------------------------------------------
# 4. 恢复后的全链路复测与对比。
# ------------------------------------------------------------------
ACTIVE_DECODERS="${DECODE_DP_SIZE}"
if [[ "${DO_DECODE}" == "0" ]]; then
    ACTIVE_DECODERS="${NEW_DECODE_DP}"
fi
run_warmup "post_recover" "${ACTIVE_DECODERS}" || exit 1
send_request "post_recover" "${POST_OUTPUT}" || exit 1

compare_outputs "${PRE_OUTPUT}" "${POST_OUTPUT}" "${REQUIRE_OUTPUT_MATCH}" \
    "post-recover output differs from pre-degrade baseline" \
    "RECOVER output is identical to pre-degrade baseline"
RC=$?
if [[ ${RC} -ne 0 ]]; then
    echo "[scenario3] test finished with failure (rc=${RC})" >&2
    exit ${RC}
fi

echo "============================================================"
echo "[scenario3] PASS: RECOVER completed."
echo "  prefill : $([[ ${DO_PREFILL} -eq 1 ]] && echo DP${DP_SIZE}TP${TP_SIZE} symmetric || echo unchanged)"
echo "  decode  : $([[ ${DO_DECODE} -eq 1 ]] && echo DP${DECODE_DP_SIZE}TP1 recovered || echo unchanged DP${NEW_DECODE_DP}TP1)"
echo "  baseline: ${PRE_OUTPUT}"
echo "  recovered: ${POST_OUTPUT}"
echo "  logs     : ${SCENARIO_LOG_DIR}"
echo "============================================================"
exit 0
