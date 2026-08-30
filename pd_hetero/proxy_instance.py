#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 向 PD 负载均衡代理添加/摘除 decode 实例。
#
# 使用方式：
#   python3 proxy_instance.py add    <proxy_host> <proxy_port> <host> <port>
#   python3 proxy_instance.py remove <proxy_host> <proxy_port> <host> <port>
#
# 退出码：0=成功；1=HTTP 调用失败；2=参数错误。

import json
import sys
import urllib.error
import urllib.request

USAGE = "usage: proxy_instance.py add|remove <proxy_host> <proxy_port> <host> <port>"


def main() -> int:
    if len(sys.argv) != 6 or sys.argv[1] not in ("add", "remove"):
        print(USAGE, file=sys.stderr)
        return 2

    action, proxy_host, proxy_port, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
    payload = {"type": "decode", "instances": f"{host}:{port}"}
    data = json.dumps(payload).encode("utf-8")
    url = f"http://{proxy_host}:{proxy_port}/instances/{action}"
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            print(body)
            if resp.status != 200:
                return 1
            # The proxy returns 200 even when an instance was only queued in
            # ``waiting_nodes`` (its /v1/models probe failed) or when the
            # instance list did not change.  Verify the reported instance
            # list so orchestration scripts fail instead of silently testing
            # with a stale decoder set.
            try:
                result = json.loads(body)
            except json.JSONDecodeError:
                print(
                    f"[proxy-instance][ERROR] {action} response is not JSON",
                    file=sys.stderr,
                )
                return 1
            current = [
                str(item)
                for item in result.get("current_decode_instances", [])
            ]
            instance = f"{host}:{port}"
            if action == "add" and instance not in current:
                print(
                    f"[proxy-instance][ERROR] add {instance} not reflected in "
                    f"proxy decode instances: {current}",
                    file=sys.stderr,
                )
                return 1
            if action == "remove" and instance in current:
                print(
                    f"[proxy-instance][ERROR] remove {instance} still present "
                    f"in proxy decode instances: {current}",
                    file=sys.stderr,
                )
                return 1
            return 0
    except (urllib.error.URLError, OSError) as exc:
        print(f"[proxy-instance][ERROR] {action} {host}:{port} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
