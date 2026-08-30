# 阶段 03：基线请求

覆盖 warmup、经 PD 代理的基线请求、D 单机直连基线请求。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| `run_warmup` | `pd_hetero/common.sh:104-144` |
| `send_request` | `common.sh:147-167` |
| `send_pd_request.py` payload | `send_pd_request.py:63-71` |
| 响应解析与校验 | `send_pd_request.py:84-129` |
| 代理 `/v1/completions` | `proxy/load_balance_proxy_server.py:883-886` |
| `_handle_completions` | `load_balance_proxy_server.py:700-835` |
| `_handle_select_instance` | `load_balance_proxy_server.py:649-686` |
| P 首跳 `send_request_to_service` | `load_balance_proxy_server.py:546-593` |
| D 流式转发 | `load_balance_proxy_server.py:596-646` |
| recomputed 重试 | `load_balance_proxy_server.py:783-804` |
| P1 基线调用 | `run_scenario1.sh:147-148` |
| P3 基线调用 | `run_scenario2.sh:158-160` |
| P7 直连基线 | `decode/run_decode_fault_alone.sh:152-169` |

## 2. 进程与线程

- 本阶段没有新进程；请求由调用方脚本内的 `python3` 临时进程发起。
- proxy 进程内以异步任务处理每个请求：
  - `generate_stream()` 协程逐 chunk 转发；
  - 每个请求记录选择的 prefill/decoder 实例与 request_id。
- P 侧：prefill engine 为 warmup 请求执行一次 1-token 预填充并注册 KV；
- D 侧：decode engine 对正式请求执行续推。

## 3. HTTP 请求

### 3.1 测试脚本 → 代理

```text
POST http://127.0.0.1:8000/v1/completions
{
  "model": "dsv4",
  "prompt": "...",
  "max_tokens": 8(warmup) 或 100(正式),
  "temperature": 0.0,
  "seed": 1024
}
```

### 3.2 代理 → prefill

代理把请求改写为：

```text
POST http://127.0.0.1:9000+i/v1/completions
max_tokens=1, min_tokens=1, stream=false
kv_transfer_params = {
  "do_remote_decode": true,
  "do_remote_prefill": false,
  "remote_engine_id": null,
  "remote_block_ids": null,
  "remote_host": null,
  "remote_port": null,
  "aborted_request": [...]
}
```

### 3.3 代理 → decode

```text
POST http://<DECODE_HOST>:9100+i/v1/completions
原请求体 + prefill 返回的 kv_transfer_params
```

## 4. 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `PROMPT` | 固定中文 prompt | 请求输入 |
| `MAX_TOKENS` | S1/S2/S3=100；D 单机=64 | 生成长度 |
| `REQUEST_TEMPERATURE` | 0.0 | 贪心解码，保证可比 |
| `REQUEST_SEED` | 1024 | 采样种子 |
| `WARMUP_REQUESTS` | S1=16；S2 基线=16；S3=16 | 覆盖全部 decoder |
| `WARMUP_RETRIES/WARMUP_INTERVAL` | 30 / 10 | recomputed 或失败时重试 |
| `PROXY_URL` | `http://127.0.0.1:8000/v1/completions` | 请求入口 |

## 5. 函数调用链

### 5.1 经代理（P1/P2/P3/P4/P5/P6）

```text
common.sh:run_warmup / send_request
  → send_pd_request.py:main
      urllib POST PROXY_URL
  → proxy:handle_completions
      → _handle_completions
          → _handle_select_instance
              ├─ select_prefiller（堆选 P）
              ├─ send_request_to_service（P 首跳 max_tokens=1）
              ├─ response.kv_transfer_params
              └─ select_decoder（负载相等时严格轮转）
          → generate_stream
              ├─ stream_service_response_with_retry（转发 D）
              ├─ 首 chunk 释放 P 的 KV 配额
              ├─ stop_reason=recomputed：
              │    重拼 prompt+已生成 text，重新 _handle_select_instance
              └─ 结束释放 decoder
```

### 5.2 D 单机直连（P7）

```text
run_decode_fault_alone.sh
  → send_pd_request.py --url http://127.0.0.1:9100/v1/completions
      不经过 proxy，直接请求 D engine
```

## 6. 本阶段在 8 条路径中的差异

| 路径 | warmup 次数 | 请求出口 | 保存基线 |
|---|---|---|---|
| P1/P2 | 16 | proxy | `logs/pd_scenario1/pre_hetero.json` |
| P3/P4 | 16 | proxy | `logs/pd_scenario2/pre_decode_fault.json` |
| P5/P6 | 无独立基线（读取历史文件） | — | S1 `pre_hetero.json` |
| P7 | 无 warmup | 直连 D rank0 | `logs/decode_fault_alone/pre_fault.json` |
| P8 | 无基线请求（前置状态校验） | — | 默认读 P7 基线 |

## 7. 不确定点

- warmup 成功判定依赖 `FINISH_REASON != recomputed`；若某个 decoder 一直 recompute，
  只能重试到上限后失败；
- 代理轮转选 D 依赖所有 decoder 负载相等，若请求并发/失败状态不同，实际覆盖顺序可能变化；
- 基线输出与后续输出完全一致的前提是 temperature=0 且模型/调度确定性，脚本未校验其它采样参数。
