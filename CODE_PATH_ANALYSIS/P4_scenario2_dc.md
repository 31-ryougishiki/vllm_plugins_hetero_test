# P4 — S2 决策中心触发（`decision_center/run_scenario2_dc.sh`）

## 目标

同 P3：D `DP16TP1 → DP15TP1`，P 不变。
差异：测试侧只调 DC `/test/trigger_fault`，DC 向 D 下发 `DEGRADE`。

## 代码运行大致流程

```text
[1] 安装与拉起
    → 见 parts/01_install_launch.md
    → 见 parts/01_service_startup.md（启动链）
    P/D 由 DC launch wrapper 拉起，统一 VLLM_SERVICE_ID

[2] 健康检查 / 代理
    → 见 parts/02_health_proxy.md
    P 4 / D 16 / proxy

[3] 基线请求
    → 见 parts/03_baseline_request.md
    → 推理执行见 parts/03_inference_execution.md
    同 P3：pre_decode_fault.json + P restart 计数

[4] 触发
    → 见 parts/04_trigger.md 的 E 节
    run_scenario2.sh:190-199 → dc_trigger_fault DECODE_HOST 15
    POST DC /test/trigger_fault
    DC → D 16 executor：deploy_type=DEGRADE
    rank0..14 new_dp=15；rank15 new_dp=0/new_tp=0
    随后 sleep 30s 等待降级稳定

[5] 重启 / 恢复执行
    → 见 parts/05_restart_recovery.md 第 1、3 节
    与 P3 相同的 15-rank barrier / rank15 Idle 链
    差异：走 _execute_degrade_strategy；
          rank15 会收到 idle 带内通知；
          EngineCore 设置 zero_interrupt_mode="degrade"

[6] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.2 节
    → 复测推理执行见 parts/03_inference_execution.md 第 5.2/5.3 节
    动态探测 D /health → ACTIVE_DECODE_COUNT
    摘除 rank15 及所有不健康 decoder
    warmup ACTIVE_DECODE_COUNT 次 → post_decode_fault.json
    P restart 计数不变 → 输出对比
```

## P4 特有差异

- 测试侧不固定目标 DP 数，以 `/health` 探测为准（`run_scenario2.sh:211-229`）；
- 当前 DC 源码整除修正函数未被调用，静态结果固定 DP15；脚本动态探测属防御性写法；
- 代理摘除范围可能大于 P3（所有不健康 decoder）。

## 关键风险

- `fault_code=80E78000` 需被 DC 支持；
- 若 DC 后续启用专家整除约束选择非 DP15，复测 decoder 数会变化；
- `sleep 30s` 是固定等待，DC 下发/重启更慢时可能误判健康。
