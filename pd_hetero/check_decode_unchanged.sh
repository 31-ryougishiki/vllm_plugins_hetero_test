#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 校验场景 1 的 D 端确实没有被异构重启。
#
# 校验内容：
#   1. 16 个 decode engine 的 /health 仍为 200；
#   2. decode 日志中本次运行期间没有新增
#      "restarting workers of EVERY DP instance"；
#   3. 可选：通过 SSH 检查 decode 节点上 vllm 主进程的启动时间未变化。
#
# 与旧版本不同，第 2 项是【计数对比】而不是“目录里必须为 0”：D 端日志是
# 追加写入的，重复执行场景（或 run_all_dc.sh 先跑过场景 2/3）会留下历史
# marker。调用方在触发前记录 EXPECTED_RESTART_MARKERS，本脚本只校验触发后
# 计数没有增长；未提供时默认要求为 0（旧行为）。
#
# 使用方式：
#   # decode 与 prefill 在同一节点（测试环境）
#   bash check_decode_unchanged.sh
#
#   # decode 在远端节点
#   SSH_DECODE="root@10.0.0.2" bash check_decode_unchanged.sh
#
# 环境变量：
#   DECODE_HOST / DECODE_VLLM_PORT_START / DECODE_DP_SIZE /
#   DECODE_LOG_DIR / SSH_DECODE / EXPECTED_RESTART_MARKERS

set -uo pipefail

DECODE_HOST="${DECODE_HOST:-127.0.0.1}"
DECODE_VLLM_PORT_START="${DECODE_VLLM_PORT_START:-9100}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"
DECODE_LOG_DIR="${DECODE_LOG_DIR:-/opt/its/z30055003/logs/decode}"
SSH_DECODE="${SSH_DECODE:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
# 触发前记录的解码侧 restart marker 总数；未提供时按旧语义要求为 0。
EXPECTED_RESTART_MARKERS="${EXPECTED_RESTART_MARKERS:-0}"
EXPECTED_RESTART_MARKERS="${EXPECTED_RESTART_MARKERS//[^0-9]/}"
[[ -n "${EXPECTED_RESTART_MARKERS}" ]] || EXPECTED_RESTART_MARKERS=0

FAIL=0

check_health() {
    local port="$1"
    "${PYTHON_BIN}" - "${DECODE_HOST}" "${port}" <<'PY'
import sys
import urllib.request

host, port = sys.argv[1], int(sys.argv[2])
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(f"http://{host}:{port}/health", timeout=5) as resp:
        sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
}

echo "[check-decode] health check ${DECODE_HOST}:${DECODE_VLLM_PORT_START}..$((DECODE_VLLM_PORT_START + DECODE_DP_SIZE - 1))"
HEALTHY=0
for ((dp_rank = 0; dp_rank < DECODE_DP_SIZE; dp_rank++)); do
    port=$((DECODE_VLLM_PORT_START + dp_rank))
    if check_health "${port}"; then
        HEALTHY=$((HEALTHY + 1))
    else
        echo "[check-decode][FAIL] decode dp${dp_rank} port=${port} is unhealthy" >&2
        FAIL=1
    fi
done
echo "[check-decode] healthy=${HEALTHY}/${DECODE_DP_SIZE}"

check_restart_marker() {
    local label="$1"
    local grep_cmd="$2"
    local output
    local status
    local count
    echo "[check-decode] ${label}: counting restart markers"
    # Capture the command's exit status separately from the line count.  A
    # failed ssh / missing remote log dir must be treated as "could not
    # verify", not as "0 markers found".
    output="$(eval "${grep_cmd}" 2>&1)"
    status=$?
    if [[ ${status} -ne 0 ]]; then
        echo "[check-decode][FAIL] ${label}: unable to inspect decode logs " \
            "(command exited ${status}): ${output}" >&2
        FAIL=1
        return
    fi
    if [[ -z "${output}" ]]; then
        count=0
    else
        count="$(printf '%s\n' "${output}" | wc -l)"
    fi
    count="${count//[^0-9]/}"
    [[ -n "${count}" ]] || count=0
    if [[ "${count}" -ne "${EXPECTED_RESTART_MARKERS}" ]]; then
        echo "[check-decode][FAIL] ${label}: restart markers changed " \
            "${EXPECTED_RESTART_MARKERS} -> ${count} (decode side was restarted)" >&2
        FAIL=1
    else
        echo "[check-decode] ${label}: restart markers unchanged (${count})"
    fi
}

if [[ -n "${SSH_DECODE}" ]]; then
    check_restart_marker "remote logs" \
        "ssh ${SSH_DECODE} \"[[ -d ${DECODE_LOG_DIR} ]] || exit 9; grep -R 'restarting workers of EVERY DP instance' ${DECODE_LOG_DIR} 2>/dev/null || true\""
    echo "[check-decode] remote vllm processes:"
    ssh "${SSH_DECODE}" "pgrep -af 'vllm.entrypoints.openai.api_server' || true"
else
    if [[ -d "${DECODE_LOG_DIR}" ]]; then
        check_restart_marker "local logs" \
            "[[ -d ${DECODE_LOG_DIR} ]] || exit 9; grep -R 'restarting workers of EVERY DP instance' ${DECODE_LOG_DIR} 2>/dev/null || true"
    else
        echo "[check-decode][FAIL] ${DECODE_LOG_DIR} not accessible locally;" >&2
        echo "  cannot verify decode side was not restarted. Set SSH_DECODE" >&2
        echo "  to inspect remote logs, or explicitly disable this check with" >&2
        echo "  CHECK_DECODE_UNCHANGED=0." >&2
        FAIL=1
    fi
fi

if [[ ${FAIL} -eq 0 ]]; then
    echo "[check-decode][PASS] decode side is healthy and was not restarted"
    exit 0
fi
echo "[check-decode][FAIL] decode side verification failed" >&2
exit 1
