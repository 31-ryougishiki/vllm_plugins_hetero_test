# P5 — S3 手动恢复（`pd_hetero/run_scenario3.sh`，both + ssh）

## 目标

前置：P `DP4TP(3,4,4,4)`，D `DP15TP1`（rank15 Idle），proxy 已摘除 rank15。
恢复：P→`DP4TP4`，D→`DP16TP1`，并把 rank15 加回代理。

## 代码运行大致流程

```text
[1] 前置状态确认
    → 见 parts/02_health_proxy.md
    P 4 / D 15（rank15 不强校验）/ proxy / P ITS 4

[2] 基线选择
    both → logs/pd_scenario1/pre_hetero.json（run_scenario3.sh:112-130）

[3] 触发 P RECOVER
    → 见 parts/04_trigger.md 的 C 节
    trigger_prefill_recover.sh POST 4 个 P ITS /executor/deploy
    deploy_type=RECOVER，4 条 new_dp=4/new_tp=4，NPU 全健康

[4] P 恢复执行
    → 见 parts/05_restart_recovery.md 第 4 节
    P: current_is_heterogeneous → full_restart
       沿用 4-rank barrier → 15 worker 退出 → 16 对称 worker 重建
       engine_id 再次轮换 + KV 元数据刷新
    D: 15 个 decoder 仍健康

[5] 触发 D RECOVER
    → 见 parts/04_trigger.md 的 D 节
    common.sh:trigger_decode_remote recover
    SSH 到 D 执行 trigger_decode_recover.sh
    16 次 POST 18001..18016 /executor/deploy，deploy_type=RECOVER

[6] D 恢复执行
    → 见 parts/05_restart_recovery.md 第 5 节
    16 个 executor 重建 16-rank barrier，全部 passed
    rank15 从 Idle 恢复 1 worker
    16 个 D /health 就绪

[7] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.3 节
    → 恢复后推理执行见 parts/03_inference_execution.md 第 5.2 节
    proxy add DECODE_HOST:9115
    warmup 16 → post_recover.json
    compare_outputs(pre_hetero.json, post_recover.json, 1)
```

## P5 特有差异

- `RECOVER_TARGET=both`、`TRIGGER_MODE=ssh`（`run_scenario3.sh:65-66`）；
- P RECOVER 与 D RECOVER 的 barrier 语义不同：P 沿用 4-rank 组，D 重建 16-rank 组；
- P 恢复后 D 的 15 个 decoder 必须仍健康（P engine_id 轮换后 Mooncake 按新元数据恢复）。

## 关键风险

- 前置状态不深查：P 只要 `/health` 200，不验证当前确实异构；
- rank15 是否 Idle 只由 D trigger 脚本间接检查；
- 若 S1 基线缺失，输出对比自动降级为只查非空。
