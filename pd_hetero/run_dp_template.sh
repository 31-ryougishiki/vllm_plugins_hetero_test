#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# launch_online_dp.py 的单实例模板：调用当前角色指定的 origin.sh。
#
# launch_online_dp.py 固定传入 7 个位置参数：
#   $1 visible_devices
#   $2 vllm_engine_port
#   $3 dp_size
#   $4 dp_rank
#   $5 dp_address
#   $6 dp_rpc_port
#   $7 tp_size
#
# 本模板只负责把同一组参数转发给 ORIGIN_SCRIPT。
# ORIGIN_SCRIPT 由 prefill/start_server.sh 或 decode/start_server.sh 注入：
#   ORIGIN_SCRIPT=prefill/origin.sh  python3 launch_online_dp.py ...
#   ORIGIN_SCRIPT=decode/origin.sh   python3 launch_online_dp.py ...

set -euo pipefail

ORIGIN_SCRIPT="${ORIGIN_SCRIPT:?export ORIGIN_SCRIPT=<role>/origin.sh}"

if [[ ! -f "${ORIGIN_SCRIPT}" ]]; then
    echo "[run-dp-template][ERROR] ORIGIN_SCRIPT not found: ${ORIGIN_SCRIPT}" >&2
    exit 1
fi

echo "[run-dp-template] role=${NODE_ROLE:-unknown} origin=${ORIGIN_SCRIPT} " \
    "devices=$1 port=$2 dp=$3/$4 addr=$5 rpc_port=$6 tp=$7"

exec bash "${ORIGIN_SCRIPT}" "$@"
