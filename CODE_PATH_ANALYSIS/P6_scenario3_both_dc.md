# P6 — S3 决策中心恢复（`decision_center/run_scenario3_dc.sh`）

## 目标

同 P5：P/D RECOVER 到对称拓扑。测试侧只调一次 DC `/repair/devices`，
由 DC 向 P/D 下发 `RECOVER`。

## 代码运行大致流程

```text
[1] 前置状态确认
    → 见 parts/02_health_proxy.md
    同 P5；wrapper START_PREFILL=0/START_PROXY=0，P/proxy 必须已存在

[2] 基线选择
    both → S1 pre_hetero.json

[3] 触发（一次合并 repair）
    → 见 parts/04_trigger.md 的 F 节
    run_scenario3.sh:176-190
    REPAIR_ARGS = [P_IP:3, D_IP:15]
    POST DC /repair/devices（一次）
    DC: 标记 NPU 健康 → 检查服务全部健康 → 向坏卡 engine 下发 RECOVER
    DC_REPAIR_SENT=1，D 分支不再发第二次

[4] P 恢复执行
    → 见 parts/05_restart_recovery.md 第 4 节
    与 P5 的 P 侧相同

[5] D 恢复执行
    → 见 parts/05_restart_recovery.md 第 5 节
    与 P5 的 D 侧相同

[6] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.3 节
    → 恢复后推理执行见 parts/03_inference_execution.md 第 5.2 节
    与 P5 相同：add 9115 → warmup 16 → post_recover.json → 对比
```

## P6 特有差异

- 测试侧不直接 POST executor，策略由 DC 下发；
- DC 修复必须一次上报服务下所有坏卡，否则不会触发恢复；
- DC 恢复对象是自身记录过 `bad_engines` 的 engine。

## 关键风险

- 如果 S1/S2 故障是手动路径制造的，DC 无 `bad_engines` 记录，repair 会跳过恢复；
- DC payload 同样不含 `tp_asymmetric_shardings`/`update_engine_info`；
- `run_scenario3.sh` 本身无 START 分支，`START_PREFILL=0/START_PROXY=0` 只是 wrapper 声明，
  实际完全依赖既有服务。
