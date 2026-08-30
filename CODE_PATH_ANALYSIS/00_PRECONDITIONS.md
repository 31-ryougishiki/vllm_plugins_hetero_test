# 前置条件与输入假设（必读）

本文档是 `CODE_PATH_ANALYSIS/` 全部文档的**编写前置条件清单**。任何路径、阶段或
推理细节结论只有在以下条件同时成立时才有效；条件不满足时，必须重新核对代码与文档。

---

## 1. 分析性质与状态

| 项 | 前置条件 |
|---|---|
| 分析方式 | **纯静态分析**：只根据脚本定义、源码分支、默认值与模型配置推导路径 |
| 实跑状态 | P1-P8 **当前均未实跑**；不引用任何真实运行日志、请求结果或性能数据 |
| 验证方式 | 文档结论需在实跑后按第 10 节 checklist 逐项核对 |
| 生效范围 | 只覆盖 `VLLM_ITS_DEEPSEEK_V4=1` 的 DeepSeek-V4 patch 族；0829 分支不展开 |
| 排除范围 | `hetero_cp`、真实 NPU 故障回调路径、算子/图编译内部实现、网络环境实现细节 |

---

## 2. 代码与仓库基线

| 仓库/目录 | 基线 | 状态要求 |
|---|---|---|
| `vllm_plugins` | 分支 `merge-unified-install`，commit `4a6a18a8196dd870423cba429ab572d0df1269c1` | 工作树干净 |
| `vllm_plugins_hetero_test` | 分支 `merge-0829-adapt`，commit `3f5e4a523a5ba18c8b97604aec413a3f795b758a`（文档提交后以 `CODE_PATH_ANALYSIS/` 所在 commit 为准） | 工作树干净 |
| vLLM 源码基线 | `origin_0.23.0/vllm`（v0.23.0） | 只用于基类调用链与默认值判定 |
| vllm-ascend 源码基线 | `origin_0.23.0/vllm-ascend`（v0.23.0） | 只用于基类调用链与默认值判定 |
| 插件运行时代码 | `vllm_plugins/vllm_custom_plugins/plugins/zero_interrupt/deepseekv4/` | 视为已安装到目标环境 |
| 统一替换文件 | `.../zero_interrupt/vllm/...` 与 `.../zero_interrupt/vllm_ascend/...` 主目录 | 视为已由 `setup.py` 替换到站点包，`.bak` 备份已生成 |
| `DecisionMakingCenter` | 工作区目录，**无 `.git`** | 用户确认本地代码与已部署 DC 完全一致 |
| 模型配置 | `DeepSeek-V4-Flash-w8a8-mtp/config.json` | 模型路径、架构、experts、heads、MTP 层数均按此文件 |

### 代码引用约定

- 插件路径引用：`vllm_plugins/vllm_custom_plugins/plugins/zero_interrupt/...`；
- vLLM 基类引用：`origin_0.23.0/vllm/vllm/...`；
- vllm-ascend 基类引用：`origin_0.23.0/vllm-ascend/vllm_ascend/...`；
- 测试脚本引用：`vllm_plugins_hetero_test/...`；
- DC 引用：`DecisionMakingCenter/...`。

---

## 3. 运行期环境前置条件

以下条件由 launch 脚本默认值提供，是文档中所有调用链的前提：

| 条件 | 值 | 证据 |
|---|---|---|
| `VLLM_ITS_DEEPSEEK_V4` | 1 | P `launch_prefill_hetero_test.sh:98`；D `launch_decode_pd.sh:102` |
| `VLLM_CUSTOM_PATCHES` | `zero_interrupt` | P `:95`；D `:99` |
| `VLLM_CUSTOM_PLUGINS_SKIP_LICENSE` | 1 | P `:101`；D `:103` |
| `VLLM_ITS_ENABLE_FAULT_KEEP` | true | P `:103`；D `:105` |
| `VLLM_ITS_ENABLE_PD_REBUILD` | true | P `:104`；D `:106` |
| `VLLM_ITS_STRATEGY_TIMEOUT` | 600 | P `:105`；D `:107` |
| `VLLM_ITS_HEALTH_CHECK_INTERVAL` | 5 | P `:106`；D `:108` |
| P ITS HTTP 端口基址 | 8001 | P `:102` |
| D ITS HTTP 端口基址 | 18001 | D `:104` |
| P vLLM 端口 | 9000..9003 | P `:130-136` |
| D vLLM 端口 | 9100..9115 | D `:130-137` |
| P topology | DP4TP4，NPU 0..15 | P `:171-176` |
| D topology | DP16TP1，NPU 0..15 | D `:178-181` |
| P kv_role | `kv_producer`，`kv_port=36000`，`engine_id=0` | P `:157-165` |
| D kv_role | `kv_consumer`，`kv_port=36200`，`engine_id=1` | D `:157-165` |
| kv extra config | prefill `dp4/tp4`，decode `dp16/tp1` | P/D `kv_connector_extra_config` |
| P model flags | `--enforce-eager`、`--quantization ascend`、`--enable-expert-parallel` | P `:136,153-154` |
| D model flags | `--async-scheduling`、`--quantization ascend`、`FULL_DECODE_ONLY` | D `:142,154,156` |
| hybrid KV manager | 两侧开启 `--no-disable-hybrid-kv-cache-manager` | P `:142`；D `:144` |
| speculative config | 两侧 `method=mtp, num_speculative_tokens=1, enforce_eager=true` | P `:146`；D `:155` |
| 非 DC 场景 DC URL | `http://127.0.0.1:1`，最大重试 1 | P `:109-110`；D `:110-111` |
| Python 解释器 | launch 默认 `PYTHON_BIN=python3`，且必须与安装 wheel 的 python 一致 | P `:36`；D `:43` |

---

## 4. 运行时开关前置条件（已由脚本判定）

完整证据见 `parts/inference/07_runtime_switches.md`，此处只列结论：

| 开关 | P | D |
|---|---|---|
| `enable_dsa_cp` | true | false |
| FlashComm1 env | 1 | 未设置（默认 0） |
| FlashComm2 | false | false |
| `enable_shared_expert_dp` | true | false |
| `mix_placement` | false | false |
| `enable_sp_by_pass` | false（P enforce_eager=true） | 需结合 D 图编译 pass 默认值 |
| hybrid KV | true | true |
| `async_scheduling` | false | true |
| fused MC2 | 未设置（默认 0） | 未设置（默认 0） |
| `multistream_overlap_shared_expert` | false | true |
| `recompute_scheduler_enable` | false | true |
| `enable_npugraph_ex` | 平台默认 | true |
| `enable_static_kernel` | 平台默认 | false |

仍保留为“运行时条件”的项：具体一次前向的 FlashComm1 SP 激活（token>1000）、
D `enable_sp_by_pass` 最终值、EP group rank 顺序、图编译命中的 kernel。

---

## 5. 各路径的独立前置条件

### P1 — S1 manual

- D 已由外部 `pd_hetero/decode/launch_decode_pd.sh` 拉起为 `DP16TP1`；
- P 未健康时由脚本按需拉起对称 `DP4TP4`；
- proxy 未运行时由脚本启动，初始 16 个 D 实例；
- `TRIGGER_MODE=manual`、`DEPLOY_TYPE=PD_REBUILD`、`FAULT_NPU=3`；
- P ITS 4 个端口 8001/8005/8009/8013 在线；
- 基线文件输出路径：`logs/pd_scenario1/pre_hetero.json`；
- `REQUIRE_OUTPUT_MATCH=1`，基线文件必须存在。

### P2 — S1 DC

- 与 P1 相同，但 `TRIGGER_MODE=dc`；
- DC URL 使用 `DECISION_CENTER_URL`（默认 `http://7.246.78.79:8088`）；
- `FAULT_NODE_IP=PREFILL_HOST`，`FAULT_NPU=3`；
- DC 的 `FAULT_CODE_CONFIG` 必须支持 `80E78000`，否则故障被静默过滤；
- 当前 DC 代码判定：S1 故障向 P 下发 `DEGRADE`。

### P3 — S2 ssh

- P 对称 `DP4TP4` 已运行；D 初始 `DP16TP1` 已运行；
- `TRIGGER_MODE=ssh` 且 `SSH_DECODE=root@<decode-ip>` 已提供；
- `DECODE_TEST_DIR` 指向 D 节点上的测试仓目录；
- `DECODE_FAULT_NPU=15`；
- D trigger 向 16 个 ITS 端口发 `PD_REBUILD`，rank15 `new_dp=0/new_tp=0`；
- 故障 rank15 不可达时只告警，不判失败。

### P4 — S2 dc

- 与 P3 的初始拓扑相同；
- `TRIGGER_MODE=dc`，DC 向 D 下发 `DEGRADE`；
- 当前 DC 源码静态判定目标为 DP15，但测试脚本按 `/health` 动态探测；
- 触发后固定 sleep 30s，DC 下发/恢复慢于 30s 时可能误判。

### P5 — S3 both+ssh

- 前置状态由 S1/S2 制造：P=`DP4TP(3,4,4,4)`，D=`DP15TP1`，rank15 Idle；
- proxy 已摘除 decoder15；
- `RECOVER_TARGET=both`、`TRIGGER_MODE=ssh`；
- `SSH_DECODE` 已提供；
- P trigger 向 4 个 ITS 端口发 `RECOVER`；
- D trigger 向 16 个 ITS 端口发 `RECOVER`；
- 基线默认 `logs/pd_scenario1/pre_hetero.json` 必须存在，否则对比自动降级为只查非空。

### P6 — S3 both dc

- 前置状态同 P5；
- `TRIGGER_MODE=dc`，`RECOVER_TARGET=both`；
- 一次 `/repair/devices` 同时上报 P NPU3 与 D NPU15；
- **DC 必须在之前的 DC 故障流程中记录过 `bad_engines`**；手动制造的 S1/S2 再调
  DC repair 不会恢复。

### P7 — D 单机 fault

- 仅 D 节点，D 初始 16 个 engine 健康或由脚本拉起；
- `DECODE_FAULT_NPU=15`；
- 不依赖 P、proxy、DC；
- 基线/复测直连 `127.0.0.1:9100`（或首个非故障 rank）。

### P8 — D 单机 recover

- 前置由 P7 制造：D 15 健康 + rank15 `Idle mode (dp=0)`；
- `RECOVER_BASELINE` 默认 `logs/decode_fault_alone/pre_fault.json`；
- 基线缺失时 `REQUIRE_OUTPUT_MATCH` 自动降级为 0。

---

## 6. 触发策略类型前置条件

| 路径 | deploy_type | 来源 |
|---|---|---|
| P1 | `PD_REBUILD` | `trigger_hetero_restart.sh:34` |
| P2 | `DEGRADE` | 当前 DC `main.py:552-558` |
| P3/P7 | `PD_REBUILD` | `trigger_decode_fault.sh:35` |
| P4 | `DEGRADE` | 当前 DC `main.py:552-558` |
| P5/P8 | `RECOVER` | `trigger_prefill_recover.sh:28` / `trigger_decode_recover.sh:34` |
| P6 | `RECOVER` | `state_monitor.py:1024` |

DC 下发 payload 的前置特征：

- 不含 `tp_asymmetric_shardings`，S1 DC 的 `[2,1,1]` 由插件 fallback 推导；
- 不含 `update_engine_info`；
- `engine_npu_healthy_state` 在 DC 出口再包一层 list。

---

## 7. 模型配置前置条件

`DeepSeek-V4-Flash-w8a8-mtp/config.json` 的关键值：

| 项 | 值 |
|---|---|
| architectures | `DeepseekV4ForCausalLM` |
| hidden_size | 4096 |
| num_hidden_layers | 43 |
| num_attention_heads | 64 |
| num_key_value_heads | 1 |
| head_dim / qk_rope_head_dim | 512 / 64 |
| q_lora_rank / o_lora_rank | 1024 / 1024 |
| o_groups | 8 |
| n_routed_experts / num_experts_per_tok | 256 / 6 |
| n_shared_experts | 1 |
| moe_intermediate_size | 2048 |
| vocab_size | 129280 |
| num_nextn_predict_layers | 1 |
| hc_mult | 4 |
| index_topk / index_n_heads / index_head_dim | 512 / 64 / 128 |

---

## 8. 文档结构与字段约定

- 入口文档：`P1..P8_*.md`，只写完整流程与本路径差异；
- 阶段子文档：`parts/01..06_*.md`，公共阶段提取复用；
- 推理细节：`parts/inference/00..07_*.md`，按公共链/对称 P/异构 P/D/KV/MTP/开关拆分；
- 每个 `parts/*.md` 必须包含：代码行号、进程与线程、HTTP 请求、环境变量、
  函数调用链、不确定点（适用时）。

---

## 9. 不成立的前置条件（明确排除）

- 真实 NPU 硬件故障触发路径；
- `VLLM_ITS_DEEPSEEK_V4=0` / 0829 patch 族；
- 非默认参数变体（`TRIGGER_MODE=local/skip`、`RECOVER_TARGET=prefill/decode`、
  自定义端口/DP 数等）——只在文档中标注，不展开；
- `hetero_cp` 源码对照；
- 已实跑日志、图 dump、性能数据。

---

## 10. 实跑前/后核对清单

1. `git -C vllm_plugins rev-parse HEAD` == 本文基线的 `4a6a18a...`；
2. `git -C vllm_plugins_hetero_test rev-parse HEAD` == 文档所在提交；
3. 两个仓库工作树干净；
4. 目标节点已安装同一 Python 环境的 wheel，且统一替换文件 `.bak` 存在；
5. 所有 P/D `dp*.log` 出现 `applying DeepSeek-V4 patch family`；
6. P 启动日志有 `VLLM_ASCEND_ENABLE_FLASHCOMM1=1` 生效、`enable_dsa_cp=true` 生效；
7. D 启动参数确认 `--async-scheduling`、`FULL_DECODE_ONLY`、`--no-disable-hybrid-kv-cache-manager`；
8. DC 部署代码与本地 `DecisionMakingCenter` 一致，且 `FAULT_CODE_CONFIG` 支持 `80E78000`；
9. 运行日志出现/不出现文档预期的 `Full-restart barrier passed/skipped`、`Idle mode (dp=0)`、
   `KV connector metadata updated successfully`；
10. 实跑结果与文档冲突时，以运行日志与当前 commit 源码为准，并更新本文档。
