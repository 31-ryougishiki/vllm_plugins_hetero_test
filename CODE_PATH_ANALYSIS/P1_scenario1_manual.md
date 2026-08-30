# P1 — S1 手动触发（`pd_hetero/run_scenario1.sh`）

## 目标

P `DP4TP4 → DP4TP(3,4,4,4)`；D `DP16TP1` 保持不变。
触发方式：直接 POST P 的 4 个 ITS executor，`deploy_type=PD_REBUILD`。

## 代码运行大致流程

```text
[1] 安装与拉起（P1 假设 D 已由外部拉起）
    → 见 parts/01_install_launch.md
    → 见 parts/01_service_startup.md（拉起后 vLLM 引擎/worker/模型加载链）
    P: 检查 9000..9003 是否健康；未健康则 launch_prefill_hetero_test.sh
       D: 假定已运行 DP16TP1（9100..9115）
    进程：4 P engine + 16 P worker + 4 ITS HTTP 线程；D 16 engine + 16 worker

[2] 健康检查 / 代理
    → 见 parts/02_health_proxy.md
    P 4 /health、D 16 /health、proxy /healthcheck、P ITS 4 /health
    进程：+1 proxy 进程（若未运行）

[3] 基线请求
    → 见 parts/03_baseline_request.md
    → 见 parts/03_inference_execution.md（请求进入后的推理执行链）
    warmup 16 次 → 基线请求 → logs/pd_scenario1/pre_hetero.json

[4] 触发
    → 见 parts/04_trigger.md 的 A 节
    run_scenario1.sh:174-188
    trigger_hetero_restart.sh POST 4 个 P ITS /executor/deploy
    deploy_type=PD_REBUILD
    DP0 new_tp=3, shardings=[2,1,1]；DP1-3 new_tp=4；NPU3 不健康

[5] 重启 / 恢复执行
    → 见 parts/05_restart_recovery.md 第 1、2 节
    P executor: _execute_pd_rebuild_strategy
      full_restart → 4-rank barrier → 旧 16 worker 退出
      → 新 15 worker（DP0=3，DP1-3=4）
      → KV cache/KVCacheManager 重建
      → P producer engine_id 轮换 + KV connector metadata 刷新
    D: 不接收策略，进程不变

[6] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.1 节
    → 复测推理执行见 parts/03_inference_execution.md 第 5.3 节（异构后 PD 链）
    D 16 健康复检 → check_decode_unchanged.sh
    warmup 16 次 → 复测 post_hetero.json
    compare_outputs(pre, post, REQUIRE_OUTPUT_MATCH=1)
```

## P1 特有差异

- `TRIGGER_MODE=manual`、`DEPLOY_TYPE=PD_REBUILD`、`FAULT_NPU=3`（`run_scenario1.sh:56-58`）。
- `WARMUP_REQUESTS=DECODE_DP_SIZE=16`（`run_scenario1.sh:68`）。
- D 由外部启动，P1 脚本只做健康检查和未重启校验。
- 本路径的 `PD_REBUILD` 全量重启分支命中；健康实例 RPC 分支不命中。

## 关键风险

- P 已健康时跳过 launch，实际 patch 族取决于既有进程；
- `FAULT_NPU` 脚本不校验属于 DP0；
- `SIMULATE_FAULT`/`DEPLOY_TYPE` 可被外部环境覆盖。
