# P2 — S1 决策中心触发（`decision_center/run_scenario1_dc.sh`）

## 目标

同 P1：P `DP4TP4 → DP4TP(3,4,4,4)`，D 不变。
差异：测试侧只调 DC `/test/trigger_fault`，由 DC 向 P 下发策略；当前 DC 源码实际
下发 `deploy_type=DEGRADE`。

## 代码运行大致流程

```text
[1] 安装与拉起
    → 见 parts/01_install_launch.md
    → 见 parts/01_service_startup.md（启动链）
    P/D 应由 decision_center/launch_*_dc.sh 拉起（统一 VLLM_SERVICE_ID）
    P2 wrapper 默认 START_PREFILL=1，若 P 未健康会复用 launch_prefill_hetero_test.sh

[2] 健康检查 / 代理
    → 见 parts/02_health_proxy.md
    与 P1 相同：P 4 / D 16 / proxy / P ITS 4

[3] 基线请求
    → 见 parts/03_baseline_request.md
    → 推理执行见 parts/03_inference_execution.md
    与 P1 相同：pre_hetero.json

[4] 触发
    → 见 parts/04_trigger.md 的 E 节
    run_scenario1.sh:163-173 → dc_trigger_fault → trigger_fault.sh
    POST DC /test/trigger_fault {"node_ip":P_IP,"npu_id":"3","fault_code":"80E78000"}
    DC → P executor：deploy_type=DEGRADE，payload 不含 tp_asymmetric_shardings

[5] 重启 / 恢复执行
    → 见 parts/05_restart_recovery.md 第 1、2 节
    P executor: _execute_degrade_strategy
      与 P1 相同的 full_restart 链（16→15 worker）
      shardings [2,1,1] 由插件 fallback 推导
      EngineCore 额外设置 zero_interrupt_mode="degrade"

[6] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.1 节
    → 复测推理执行见 parts/03_inference_execution.md 第 5.3 节
    与 P1 相同
```

## P2 特有差异

- `TRIGGER_MODE=dc`、`FAULT_NODE_IP=PREFILL_HOST`（`run_scenario1_dc.sh:25-31`）。
- 测试侧不构造 executor payload，策略由 DC 生成；
- executor_id 为 DC 分配的 `exe-...` 或数字，ITS HTTP server 两者均接受；
- DC 当前源码 `PD_REBUILD` 分支不可达，实际 deploy_type 为 `DEGRADE`。

## 关键风险

- `fault_code=80E78000` 必须被 DC `FAULT_CODE_CONFIG` 支持，否则静默过滤；
- DC payload 无 shardings，`[2,1,1]` 完全依赖插件 fallback；
- DC 只对坏卡 engine 下发，因此 D 不会收到策略（与场景定义一致，但依赖 DC 分组正确）。
