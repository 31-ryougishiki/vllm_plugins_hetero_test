# 阶段 06：复测与校验

覆盖重启/恢复后的复测、代理 add/remove、D 未变校验、输出对比。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| P1 复测 warmup/请求 | `run_scenario1.sh:220-221` |
| P1 D 未重启校验 | `run_scenario1.sh:224-230` |
| `check_decode_unchanged.sh` | `pd_hetero/check_decode_unchanged.sh:34-89` |
| P1 输出对比 | `run_scenario1.sh:235-242` |
| S2 摘除故障 decoder | `run_scenario2.sh:255-274` |
| S2 复测 | `run_scenario2.sh:279-281` |
| S2 P restart 计数校验 | `run_scenario2.sh:286-298` |
| S2 输出对比 | `run_scenario2.sh:303-310` |
| S3 加回 decoder | `run_scenario3.sh:271-274` |
| S3 复测 | `run_scenario3.sh:285-290` |
| S3 输出对比 | `run_scenario3.sh:292-299` |
| `compare_outputs` | `pd_hetero/common.sh:170-220` |
| D 单机复测/对比 | `decode/run_decode_fault_alone.sh:223-274`；`run_decode_recover_alone.sh:161-221` |

## 2. 进程与线程

- 复测请求：测试脚本的临时 `python3` 进程；
- proxy 进程内每个请求 1 个流式转发协程；
- 本阶段不重启任何服务进程；
- 若触发过 D 缩容，故障 decoder 的 worker 已不存在（或 Idle）；若已恢复，重新有 1 个 worker。

## 3. HTTP 请求

| 端点 | 用途 |
|---|---|
| `POST /instances/remove` | S2 摘除 `DECODE_HOST:9115`（及 DC 模式下所有不健康 decoder） |
| `POST /instances/add` | S3 加回 `DECODE_HOST:9115` |
| `POST /v1/completions`（proxy） | 复测请求，保存 `post_*.json` |
| `POST /v1/completions`（直连 D） | P7/P8 复测 |
| `GET /health` | 复测前的存活确认 |

## 4. 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `REQUIRE_OUTPUT_MATCH` | 1 | 1=前后输出必须一致；0=只要求非空 |
| `CHECK_DECODE_UNCHANGED` | 1 | S1 是否执行 D 未重启校验 |
| `SSH_DECODE` | 空 | `check_decode_unchanged.sh` 远端日志检查用 |
| `WARMUP_REQUESTS` | S2 降级后 15；S3 恢复后 16 | 复测 warmup 次数 |
| `BASELINE_OUTPUT` | S3 按 `RECOVER_TARGET` 自动选择 | 对比基线 |
| `RECOVER_BASELINE` | P8 默认 `decode_fault_alone/pre_fault.json` | D 单机恢复基线 |
| `PROXY_API_HOST/PROXY_PORT` | 127.0.0.1 / 8000 | 实例管理接口 |

## 5. 函数调用链

### 5.1 S1（P1/P2）

```text
run_scenario1.sh
  → run_warmup（16 次）
  → send_request → post_hetero.json
  → check_decode_unchanged.sh
      check_health ×16
      本地/SSH grep restart marker
  → common.sh:compare_outputs
      Python 读 pre/post JSON
      比较 choices[0].text
      空输出失败；不匹配失败（REQUIRE_OUTPUT_MATCH=1）
```

### 5.2 S2（P3/P4）

```text
run_scenario2.sh
  → proxy_instance.py remove DECODE_HOST:9115
      proxy.remove_decoders
  → run_warmup（15 次，P4 为 ACTIVE_DECODE_COUNT）
  → send_request → post_decode_fault.json
  → 前后 P restart marker 计数比较
  → compare_outputs
```

### 5.3 S3（P5/P6）

```text
run_scenario3.sh
  → proxy_instance.py add DECODE_HOST:9115
      proxy.add_decoders
  → run_warmup（16 次）
  → send_request → post_recover.json
  → compare_outputs（基线按 RECOVER_TARGET 选择）
```

### 5.4 D 单机（P7/P8）

```text
run_decode_fault_alone.sh
  → 直连 decode /v1/completions
  → 内嵌 Python 比较 pre/post text
run_decode_recover_alone.sh
  → 直连 decode /v1/completions
  → 基线缺失时 REQUIRE_OUTPUT_MATCH 降级为 0
  → 内嵌 Python 比较
```

## 6. 本阶段在 8 条路径中的差异

| 路径 | 复测出口 | 代理变更 | 额外校验 |
|---|---|---|---|
| P1/P2 | proxy | 无 | `check_decode_unchanged.sh` |
| P3 | proxy | remove 9115 | P restart 计数不变 |
| P4 | proxy | remove 9115 + 所有不健康 decoder | P restart 计数不变 |
| P5 | proxy | add 9115 | 无 |
| P6 | proxy | add 9115 | 无 |
| P7 | 直连 D | 无 | rank15 idle best-effort |
| P8 | 直连 D | 无 | 无 |

## 7. 不确定点

- `compare_outputs` 在基线缺失时自动降级为“只查非空”，不报失败；
- `check_decode_unchanged.sh` 若未提供 `SSH_DECODE`，远端 D 日志 marker 检查退化为 WARN；
- 输出一致的前提是温度 0、seed 固定、两次独立请求的调度确定性；
- P7 的 rank15 idle 检查只等 30s 且失败仅告警；
- P4 的 `ACTIVE_DECODE_COUNT` 由 `/health` 动态探测得到，最终摘除范围随 DC 实际结果变化。
