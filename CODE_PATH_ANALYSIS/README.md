# CODE_PATH_ANALYSIS 目录式文档（总索引）

> 状态：**静态分析稿，P1-P8 当前均未实跑**。本文档回答“按脚本定义与当前源码，每条路径准备走哪些代码”，
> 实际结果仍需运行日志交叉确认。

## 1. 基线与输入假设

| 项 | 值 |
|---|---|
| `vllm_plugins` | `merge-unified-install` @ `4a6a18a8196dd870423cba429ab572d0df1269c1`，工作树干净 |
| `vllm_plugins_hetero_test` | `merge-0829-adapt` @ `3f5e4a523a5ba18c8b97604aec413a3f795b758a`，工作树干净 |
| `DecisionMakingCenter` | 工作区目录（无 `.git`）；用户确认与部署版代码一致，样例 IP/端口仅为举例 |
| 运行期开关 | `VLLM_ITS_DEEPSEEK_V4=1`、`VLLM_CUSTOM_PATCHES=zero_interrupt`，只深入 DeepSeek-V4 族 |
| 底座 | DeepSeek-V4-Flash-w8a8-mtp；vLLM / vllm-ascend v0.23.0（源码引用 `origin_0.23.0/vllm`、`origin_0.23.0/vllm-ascend`） |
| 环境变量 | 全部按脚本默认值；`DECODE_HOST`、`SSH_DECODE=root@<decode-ip>` 视为外部已提供 |
| 分析范围 | 测试脚本 / PD 代理 / DC 测试侧调用链 + `deepseekv4/` 运行时 patch + setup.py 统一整文件替换；`hetero_cp` 不在范围 |

## 2. 结论速览

1. **仅凭测试脚本不能唯一确定实际运行代码路径**；脚本固定的是“意图路径”。本文在固化上述基线/环境后，
   静态推导出 P1-P8 的预期执行路径。
2. 最关键分叉：手动 S1/S2 走 `PD_REBUILD`，DC S1/S2 走 `DEGRADE`（由当前 DC 源码确定）；
   S3 两条路径均为 `RECOVER`。
3. 所有拓扑变化都复用 `_cleanup_and_restart_workers` 全量重启链，但 P 异构、D 缩容、
   P 恢复、D 恢复在 barrier 建组和 worker 数量变化上不同。

## 3. 文档结构

```text
CODE_PATH_ANALYSIS/
├── README.md                  ← 本文件（总索引、基线、路径表、阅读顺序）
├── P1_scenario1_manual.md     ← S1 手动：P DP4TP4→DP4TP(3,4,4,4)
├── P2_scenario1_dc.md         ← S1 DC
├── P3_scenario2_ssh.md        ← S2 SSH：D DP16TP1→DP15TP1
├── P4_scenario2_dc.md         ← S2 DC
├── P5_scenario3_both_ssh.md   ← S3 手动：P/D RECOVER
├── P6_scenario3_both_dc.md    ← S3 DC
├── P7_decode_fault_alone.md   ← D 单机降级
├── P8_decode_recover_alone.md ← D 单机恢复
└── parts/
    ├── 01_install_launch.md       ← 安装与拉起（脚本/进程/插件）
    ├── 01_service_startup.md      ← 拉起后推理服务启动链（vLLM 引擎/worker/模型加载）
    ├── 02_health_proxy.md         ← 健康检查/代理
    ├── 03_baseline_request.md     ← 基线请求（测试侧/代理侧）
    ├── 03_inference_execution.md  ← 正常请求的推理执行链（API→EngineCore→worker→模型）
    ├── 04_trigger.md              ← 触发（manual executor / DC）
    ├── 05_restart_recovery.md     ← 策略执行/重启/恢复
    └── 06_verify_compare.md       ← 复测与校验
```

## 4. P1-P8 路径表

| 路径 | 入口脚本 | 变化 | deploy_type | 触发侧 | 入口文档 |
|---|---|---|---|---|---|
| P1 | `pd_hetero/run_scenario1.sh` | P→异构，D 不动 | `PD_REBUILD` | 直连 P ITS | `P1_scenario1_manual.md` |
| P2 | `decision_center/run_scenario1_dc.sh` | P→异构，D 不动 | `DEGRADE` | DC | `P2_scenario1_dc.md` |
| P3 | `pd_hetero/run_scenario2.sh`（ssh） | D→DP15，P 不动 | `PD_REBUILD` | SSH 到 D | `P3_scenario2_ssh.md` |
| P4 | `decision_center/run_scenario2_dc.sh` | D→DP15，P 不动 | `DEGRADE` | DC | `P4_scenario2_dc.md` |
| P5 | `pd_hetero/run_scenario3.sh`（both+ssh） | P/D RECOVER | `RECOVER` | 直连 P ITS + SSH 到 D | `P5_scenario3_both_ssh.md` |
| P6 | `decision_center/run_scenario3_dc.sh` | P/D RECOVER | `RECOVER` | DC repair | `P6_scenario3_both_dc.md` |
| P7 | `pd_hetero/decode/run_decode_fault_alone.sh` | D→DP15，无 P/代理 | `PD_REBUILD` | 本机直连 D ITS | `P7_decode_fault_alone.md` |
| P8 | `pd_hetero/decode/run_decode_recover_alone.sh` | D→DP16，无 P/代理 | `RECOVER` | 本机直连 D ITS | `P8_decode_recover_alone.md` |

## 5. 阅读顺序

1. 先读目标路径的 `Pn_*.md` 的“整体流程”，确认该路径由哪些阶段组成；
2. 再按流程中的链接进入 `parts/` 子文档查看每阶段的代码行、进程、HTTP、环境变量、调用链；
3. 启动相关阶段除 `01_install_launch.md`（脚本/插件）外，还要读
   `01_service_startup.md`（vLLM 引擎/worker/模型加载）；
4. 所有带请求的阶段除 `03_baseline_request.md`（测试侧/代理侧）外，还要读
   `03_inference_execution.md`（API→EngineCore→worker→模型的完整推理链）；
5. 多个路径相同的阶段复用同一子文档；路径特有差异在各 `Pn_*.md` 的“本路径差异”小节中说明。

## 6. 子文档字段约定

每个 `parts/*.md` 按以下字段组织（适用时列出）：

- **代码行号**：测试仓/插件仓/DC 源码相对路径 `文件:行号`；
- **进程与线程**：本阶段哪些进程/线程启动、存活、退出或重启；
- **HTTP 请求**：端点、方法、payload 关键字段、响应判定；
- **环境变量**：本阶段使用的变量、默认值、是否可覆盖；
- **函数调用链**：模块.函数级别的顺序；
- **不确定点**：静态无法唯一判定的分支或风险。

## 7. 关键风险（详见各子文档“不确定点”）

- P1-P8 均未实跑；
- DC 的 `fault_code=80E78000` 必须被 `FAULT_CODE_CONFIG` 支持，否则故障被静默过滤；
- P6 的 DC RECOVER 依赖 DC 此前记录 `bad_engines`（手动制造故障后再调 repair 不会恢复）；
- 当前 DC 源码中 `PD_REBUILD` 分支不可达，S1/S2 DC 实际下发 `DEGRADE`；
- 测试脚本不闭环校验 patch 族和安装 commit，运行前需按 HETERO_DEBUG.md 检查日志。
