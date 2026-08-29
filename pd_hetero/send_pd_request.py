#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# PD 分离场景 1 的请求发送与结果校验工具。
#
# 直接向负载均衡代理（默认 http://127.0.0.1:8000）发送 OpenAI
# /v1/completions 请求，并保存原始 JSON 与生成的纯文本。
#
# 使用示例：
#   python3 send_pd_request.py \
#       --url http://127.0.0.1:8000/v1/completions \
#       --prompt '请解释一下量子计算的基本原理。量子计算的基本原理是：' \
#       --max-tokens 100 \
#       --output /opt/its/z30055003/logs/pd_scenario1/pre_hetero.json
#
# 校验规则（任一不满足退出码非 0）：
#   --require-nonempty  生成的 text 不能为空（默认开启）
#   --require-prefix    生成的 text 必须以给定字符串开头（可选）
#   --min-tokens        生成的 completion_tokens 必须 >= N（可选）

import argparse
import json
import sys
import urllib.request
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:8000/v1/completions",
        help="proxy /v1/completions endpoint",
    )
    parser.add_argument("--model", default="dsv4")
    parser.add_argument(
        "--prompt",
        default="请解释一下量子计算的基本原理。量子计算的基本原理是：",
    )
    parser.add_argument("--max-tokens", type=int, default=100)
    parser.add_argument(
        "--temperature",
        type=float,
        default=0.0,
        help="sampling temperature; 0 uses greedy decoding so separate "
        "pre/post requests are deterministic and comparable",
    )
    parser.add_argument("--seed", type=int, default=1024)
    parser.add_argument("--output", default=None, help="save raw JSON here")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument(
        "--require-nonempty",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="fail if generated text is empty",
    )
    parser.add_argument("--require-prefix", default=None)
    parser.add_argument("--min-tokens", type=int, default=1)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    payload = {
        "model": args.model,
        "prompt": args.prompt,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "seed": args.seed,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        args.url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=args.timeout) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    response = json.loads(body)

    choices = response.get("choices") or []
    if not choices:
        print("RESULT_TEXT=<empty>")
        print(f"RESPONSE={body}")
        print("[FAIL] response has no choices")
        return 2
    choice = choices[0]
    text = choice.get("text") or ""
    usage = response.get("usage") or {}
    completion_tokens = int(usage.get("completion_tokens", 0))
    finish_reason = choice.get("finish_reason")

    print("RESULT_TEXT=" + text)
    print(f"FINISH_REASON={finish_reason}")
    print(f"COMPLETION_TOKENS={completion_tokens}")

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(body, encoding="utf-8")
        text_path = out_path.with_suffix(".text")
        text_path.write_text(text, encoding="utf-8")
        print(f"RAW_JSON={out_path}")
        print(f"TEXT_FILE={text_path}")

    rc = 0
    if args.require_nonempty and not text:
        print("[FAIL] generated text is empty")
        rc = 1
    if args.min_tokens and completion_tokens < args.min_tokens:
        print(
            f"[FAIL] completion_tokens={completion_tokens} < "
            f"min_tokens={args.min_tokens}"
        )
        rc = 1
    if args.require_prefix is not None and not text.startswith(
        args.require_prefix
    ):
        print(
            f"[FAIL] text does not start with expected prefix: "
            f"{args.require_prefix!r}"
        )
        rc = 2
    if rc == 0:
        print("[OK] request completed and basic checks passed")
    return rc


if __name__ == "__main__":
    sys.exit(main())
