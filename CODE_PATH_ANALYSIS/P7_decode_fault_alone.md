# P7 — D 单机降级（`pd_hetero/decode/run_decode_fault_alone.sh`）

## 目标

仅在 D 节点验证 `DP16TP1 → DP15TP1`，不依赖 P 和 PD 代理。

## 代码运行大致流程

```text
[1] 安装与拉起
    → 见 parts/01_install_launch.md
    → 见 parts/01_service_startup.md（启动链）
    检查 16 个 D /health；未健康则 launch_decode_pd.sh

[2] 健康检查
    → 见 parts/02_health_proxy.md 的 D 单机部分
    16 个 D /health，无 P/proxy

[3] 基线请求
    → 见 parts/03_baseline_request.md 第 5.2 节
    → 直连推理执行见 parts/03_inference_execution.md 第 5.4 节
    直连 127.0.0.1:9100/v1/completions（首个非故障 rank）
    保存 logs/decode_fault_alone/pre_fault.json
    无 warmup

[4] 触发
    → 见 parts/04_trigger.md 的 B 节
    本机执行 decode/trigger_decode_fault.sh
    16 次 POST 18001..18016 /executor/deploy，deploy_type=PD_REBUILD
    rank15 new_dp=0/new_tp=0

[5] 重启 / 恢复执行
    → 见 parts/05_restart_recovery.md 第 1、3 节
    与 P3 的 D 侧完全相同：
      15-rank barrier、dp_group 16→15、rank15 skipped → Idle

[6] 复测与校验
    → 见 parts/06_verify_compare.md 第 5.4 节
    → 复测推理执行见 parts/03_inference_execution.md 第 5.4 节
    直连同一健康 D 端口复测
    rank15 日志 Idle mode (dp=0) best-effort 30s
    内嵌 Python 对比 pre/post text
```

## P7 特有差异

- 不经代理，无法覆盖 PD 链路、代理摘除、P 侧 KV 元数据恢复校验；
- `MAX_TOKENS=64`；无 warmup；
- 若 D 已健康则跳过 launch，patch 族取决于既有进程。

## 关键风险

- 只验证 D 单机数据面/控制面子集；
- rank15 idle 检查失败不判失败；
- 无 P 时仍为 `kv_consumer`，PD 元数据刷新代码仍会执行，但无对端可验证。
