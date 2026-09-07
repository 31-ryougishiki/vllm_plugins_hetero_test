#!/usr/bin/env bash
# minimal/proxy: 简化版 PD 负载均衡代理，直接调本目录的 load_balance_proxy_server.py。
set -euo pipefail

cd "$(dirname "$0")"

PROXY_HOST="${PROXY_HOST:-0.0.0.0}"
PROXY_PORT="${PROXY_PORT:-8000}"
PREFILL_HOST="${PREFILL_HOST:-7.246.78.74}"
PREFILL_PORT_START="${PREFILL_PORT_START:-9000}"
PREFILL_DP_SIZE="${PREFILL_DP_SIZE:-4}"
DECODE_HOST="${DECODE_HOST:-7.246.78.76}"
DECODE_PORT_START="${DECODE_PORT_START:-9100}"
DECODE_DP_SIZE="${DECODE_DP_SIZE:-16}"

PREFILL_PORTS="$(seq "${PREFILL_PORT_START}" "$((PREFILL_PORT_START + PREFILL_DP_SIZE - 1))")"
DECODE_PORTS="$(seq "${DECODE_PORT_START}" "$((DECODE_PORT_START + DECODE_DP_SIZE - 1))")"
PREFILL_HOSTS="$(printf "%.0s${PREFILL_HOST} " $(seq "${PREFILL_DP_SIZE}"))"
DECODE_HOSTS="$(printf "%.0s${DECODE_HOST} " $(seq "${DECODE_DP_SIZE}"))"

exec python3 load_balance_proxy_server.py \
    --host "${PROXY_HOST}" \
    --port "${PROXY_PORT}" \
    --prefiller-hosts ${PREFILL_HOSTS} \
    --prefiller-ports ${PREFILL_PORTS} \
    --decoder-hosts ${DECODE_HOSTS} \
    --decoder-ports ${DECODE_PORTS}
