# P3 — S2 SSH 手动触发（`pd_hetero/run_scenario2.sh`）

## 目标

D `DP16TP1 → DP15TP1`；P `DP4TP4` 保持不变。
触发方式：SSH 到 D 节点执行 `decode/trigger_decode_fault.sh`，
向 16 个 D executor 发 `PD_REBUILD`。

## 代码运行大致流程

```text
[1] 安装与拉起
    → 见 parts/01_install_launch.md
    → 见 parts/01_service_startup.md（启动链）
    P: 检查后按需拉起对称 DP4TP4
    D: 假定已由 launch_decode_pd.sh 拉起 DP16TP1

[2] 健康检查 / 代理
    → 见 parts/02_health_proxy.md
    P 4 / D 16 / proxy

[3] 基线请求
    → 见 parts/03_baseline_request.md
    → 推理执行见 parts/03_inference_execution.md
    warmup 16 → pre_decode_fault.json
    记录 P restart marker 计数（run_scenario2.sh:163-167）

[4] 触发
    → 见 parts/04_trigger.md 的 B 节
    run_scenario2.sh:172-179 → common.sh:trigger_decode_remote fault
    SSH 到 D 执行 trigger_decode_fault.sh
    16 次 POST 127.0.0.1:18001..18016 /executor/deploy
    deploy_type=PD_REBUILD
    rank0..14 new_dp=15/new_tp=1；rank15 new_dp=0/new_tp=0；NPU15 不健康

[5] 重启 / 恢复执行
    → 见 parts/05_restart_recovery.md 第 1、3 节
    健康 executor 0..14: 15-rank barrier → dp_group 16→15 → 各重建 1 worker
    executor15: barrier skipped → world_size=0 → Idle mode (dp=0)
    P: 不接收策略

[6] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.2 节
    → 复测推理执行见 parts/03_inference_execution.md 第 5.2/5.3 节
    代理 remove DECODE_HOST:9115
    warmup 15 → post_decode_fault.json
    P restart 计数不变 → compare_outputs
```

## P3 特有差异

- `TRIGGER_MODE=ssh` 且 `SSH_DECODE` 必须外部提供（`run_scenario2.sh:64-65`）；
- `DECODE_TEST_DIR` 决定 D 节点实际执行的 trigger 脚本目录；
- D 触发脚本会等待 rank0..14 的 barrier marker 和 15 个 `/health` 后才返回。

## 关键风险

- 若 rank15 不可达，POST 失败仅告警，健康 executor 仍独立完成缩容；
- 测试侧不校验 D 实际 `new_dp/new_tp`，只以 15 个 `/health` 和 barrier marker 为证据；
- P3 的 rank15 因 deploy_type=PD_REBUILD 不触发 idle 带内通知（与 P4 不同）。
