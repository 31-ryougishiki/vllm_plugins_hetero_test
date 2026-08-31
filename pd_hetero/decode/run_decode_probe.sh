#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 向 decode engine 连续发送 N 个完全相同的确定性请求，用于判断 DP15 /
# DP16 / ALLGATHER 各路径是否存在跨请求差异。
#
# 用法：
#   VLLM_PORT=9100 N_REPEATS=5 \
#   bash run_decode_probe.sh 2>&1 | tee log/curl_probe.log
#
# 环境变量：
#   VLLM_PORT / MODEL / PROMPT / MAX_TOKENS / TEMPERATURE / SEED / N_REPEATS

set -euo pipefail

VLLM_PORT="${VLLM_PORT:-9100}"
MODEL="${MODEL:-dsv4}"
PROMPT="${PROMPT:-请介绍一下量子计算的原理：}"
MAX_TOKENS="${MAX_TOKENS:-64}"
TEMPERATURE="${TEMPERATURE:-0.0}"
SEED="${SEED:-1024}"
N_REPEATS="${N_REPEATS:-5}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"

payload() {
    printf '{"model": "%s", "prompt": "%s", "max_tokens": %s, "temperature": %s, "seed": %s}' \
        "${MODEL}" "${PROMPT}" "${MAX_TOKENS}" "${TEMPERATURE}" "${SEED}"
}

for _i in $(seq 1 "${N_REPEATS}"); do
    echo "===== repeat ${_i} ====="
    curl -s "http://127.0.0.1:${VLLM_PORT}/v1/completions" \
        -H 'Content-Type: application/json' \
        -d "$(payload)"
    echo
    sleep "${SLEEP_BETWEEN}"
done
