# P8 — D 单机恢复（`pd_hetero/decode/run_decode_recover_alone.sh`）

## 目标

仅在 D 节点验证 `DP15TP1 → DP16TP1`，前置状态由 P7 或 S2 制造。

## 代码运行大致流程

```text
[1] 前置状态确认
    → 见 parts/02_health_proxy.md 的 D 单机部分
    rank15 日志查 Idle mode (dp=0)（WARN 级）
    其余 15 个 D /health

[2] 基线选择
    默认 logs/decode_fault_alone/pre_fault.json（RECOVER_BASELINE 可覆盖）

[3] 触发
    → 见 parts/04_trigger.md 的 D 节
    本机执行 decode/trigger_decode_recover.sh
    16 次 POST 18001..18016 /executor/deploy，deploy_type=RECOVER

[4] 恢复执行
    → 见 parts/05_restart_recovery.md 第 5 节
    16 个 executor 重建 16-rank barrier，全部 passed
    rank15 从 Idle 恢复 1 worker
    16 个 D /health

[5] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.4 节
    → 直连推理执行见 parts/03_inference_execution.md 第 5.4 节
    直连 rank0（fault=0 时 rank1）复测
    与 pre_fault.json 对比；基线缺失则只查非空
```

## P8 特有差异

- 无 P、无代理 add，不能覆盖 PD 链路恢复校验；
- 复测刻意避开恢复的 executor 自身端口；
- 与 P5 的 D 侧 executor 链相同。

## 关键风险

- 前置 rank15 idle 检查是 WARN 级，可缺失；
- 若 rank15 未收到过 P7 缩零策略（无 backup），RECOVER 退化为按当前配置恢复，
  但目标 dp≠当前 dp 仍触发全量重启；
- 基线缺失自动降级为只查非空。
