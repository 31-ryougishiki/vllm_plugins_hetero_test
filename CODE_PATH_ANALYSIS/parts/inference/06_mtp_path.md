# 推理细节 06：MTP 路径

描述 `--speculative-config '{"num_speculative_tokens":1,"method":"mtp","enforce_eager":true}'`
在 DeepSeek-V4-Flash-w8a8-mtp 上的 drafter/proposer/验证路径。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| speculative config 构造 | `origin_0.23.0/vllm/vllm/engine/arg_utils.py:1463-1466,1665-1700,2012-2015,2241` |
| `SpeculativeConfig.__post_init__` mtp 分支 | `origin_0.23.0/vllm/vllm/config/speculative.py:525-809` |
| deepseek_v4→DeepSeekV4MTPModel 改写 | `speculative.py:314-319`；Ascend 版 `origin_0.23.0/vllm-ascend/vllm_ascend/patch/platform/patch_speculative_config.py:15-25,137` |
| method mtp → proposer | `origin_0.23.0/vllm-ascend/vllm_ascend/spec_decode/__init__.py:34-55` |
| `use_eagle` / `use_step3p5_mtp` | `speculative.py:1062-1071` |
| runner drafter 创建 | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/model_runner_v1.py:618-651` |
| DeepSeek-V4 MTP 模型类 | `origin_0.23.0/vllm-ascend/vllm_ascend/models/deepseek_v4_mtp.py:59-257` |
| 目标模型 MTP buffer | `origin_0.23.0/vllm-ascend/vllm_ascend/models/deepseek_v4.py:1079-1087,1136-1155,1304-1308` |
| MTP 权重加载 patch | `vllm_plugins/.../deepseekv4/vllm_ascend/models/patch_deepseek_v4_mtp.py:34-290,291-299` |
| hetero proposer patch | `vllm_plugins/.../deepseekv4/vllm_ascend/spec_decode/patch_hetero_spec_decode.py:24-96` |
| Ascend base proposer | `origin_0.23.0/vllm-ascend/vllm_ascend/spec_decode/llm_base_proposer.py:150-...` |
| Ascend Eagle proposer | `origin_0.23.0/vllm-ascend/vllm_ascend/spec_decode/eagle_proposer.py:10-...` |
| model runner spec 路径 | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/model_runner_v1.py:473-506,862-1374,1525-1611,1950-2401,2404-2549,2616-2642` |
| rejection sampler | `origin_0.23.0/vllm-ascend/vllm_ascend/sample/rejection_sampler.py:147-261,283-349,437-442,913-925` |

## 2. 进程与线程

- proposer 运行在 worker 进程内（NPUModelRunner 持有 proposer）；
- prefill 与 decode 阶段都可能在 worker 内执行 draft 前向；
- 不新增独立进程。

## 3. HTTP 请求

无额外 HTTP；`speculative_config` 在启动 CLI 传入。

## 4. 环境变量

- CLI：`--speculative-config '{"num_speculative_tokens":1,"method":"mtp","enforce_eager":true}'`；
- 模型配置：`num_nextn_predict_layers=1`；
- `VLLM_ITS_DEEPSEEK_V4=1` 决定 MTP 异构 patch 生效。

## 5. 调用链

### 5.1 配置与 proposer 选择

```text
AsyncEngineArgs 解析 --speculative-config
  → SpeculativeConfig.__post_init__（origin vllm/config/speculative.py）
       method=mtp
       读取 hf_config.num_nextn_predict_layers=1
       构造 draft_model_config（MTP 块）
  → get_spec_decode_method("mtp")
       use_step3p5_mtp() == False（model_type 不是 step3p5_mtp）
       → AscendEagleProposer
```

### 5.2 目标模型 prefill/decode

```text
主模型前向（DeepseekV4Model.forward）
  → 43 层 target 前向
  → FlashComm1 时 all_gather hidden states
  → _mtp_hidden_buffer[:num_tokens] 保存 pre-hc_head residual
  → get_mtp_target_hidden_states() 供 proposer 读取
```

### 5.3 proposer 提出 draft token

```text
sample_tokens 内 propose_draft_token_ids（model_runner_v1.py:1664-1917）
  → 取 target get_mtp_target_hidden_states()（1832-1840）
  → spec_decode_metadata None（prefill 后第一步）：直接按当前 tokens 准备 drafter 输入
     spec_decode_metadata 非空：prepare_inputs_padded 按 token_indices 切片（1861-1895）
  → AscendSpecDecodeBaseProposer._propose（llm_base_proposer.py:728-1037）
      set_inputs_first_pass（1337-1399）
      _sync_metadata_across_dp(is_draft_model=True)（799-803）
      draft attention metadata（888-913,975-993）
      _run_merged_draft（1054-1335）
        DeepSeekV4MTP.forward（1092）
        compute_draft_token_ids（1039-1052）
        greedy_sample → TP 组内 all_gather argmax（120-134）
      num_speculative_tokens==1 → 直接返回 [B,1]（1182-1185）
  → _draft_token_ids 异步拷回 CPU，下一轮调度使用
```

### 5.4 验证与接受

```text
scheduler 把 num_speculative_tokens=1 的 draft tokens 交给 model runner
  → _prepare_inputs 有 scheduled_spec_decode_tokens 时：
      use_spec_decode=true（1296）
      _calc_spec_decode_metadata（1334-1338,1525-1611）
  → target 前向（2290-2322）
  → sample_tokens：
      _sample 走 AscendRejectionSampler（2457-2458,2616-2641）
      target/bonus logits（rejection_sampler.py:187-227）
      greedy 且 spec_len=1 → rejection_greedy_sample_spec_len_1_pytorch（913-925）
  → 输出 [B, 2] sampled_token_ids（437-442）
```

## 6. 对称 vs 异构 MTP 差异

| 项 | 对称 DP4TP4 | 异构 DP4TP(3,4,4,4) |
|---|---|---|
| MTP 权重切分 | 均匀 TP | `[2,1,1]`（patch `_patched_mtp_load_weights`） |
| draft metadata padding | 按 TP=4 | 不按 LCM(all TP) 补齐（`_mark_dsa_cp_draft_builders`） |
| draft_tp_size 校验 | 常规 | `_patched_proposer_init` 检查 draft_tp_size，避免按 DP0 tp=3 快照错误构建 |
| target hidden buffer | FlashComm1 下 all_gather | 同样 all_gather，MTP 层接收全 token 集 |

**D DP16TP1 同样执行 MTP**（若启动参数一致）：`_set_up_drafter` 只看 speculative_config
与 last PP rank；D TP1 下 draft TP=1，`tp_group_context=nullcontext`，64 heads 全量，
EP=16 无余数，异构 patch 的 ratios 分支不生效。对 PD 解码 `seq_len=1`，`_build_attn_state`
强制走 `SpecDecoding`（`model_runner_v1.py:1481-1486`）。

## 7. 不确定点

- **脚本可判定**：P/D launch 均带 `--speculative-config method=mtp`，因此 D 也会创建
  `AscendEagleProposer`；P `enable_dsa_cp=true`、D `enable_dsa_cp=false`、
  `mix_placement=false`（详见 `07_runtime_switches.md`）；
- `hf_config_override` 的生效版本取决于 vllm-ascend patch 的导入时机，两版差异只是
  是否写 `n_predict`，本配置显式 `num_speculative_tokens=1` 不受影响；
- 异构 `_sync_metadata_across_dp` 的 EP group 组成与 dp_size 槽位对应关系需运行时确认；
- D TP1 下 MTP 的 EP 行为取决于是否开启 expert parallel；
- 接受率/耗时差异不影响最终输出正确性（HETERO_DEBUG 回归铁律 4），但路径存在。

## 8. 张量形状速查（num_speculative_tokens=1）

| 张量 | 形状 |
|---|---|
| `scheduled_spec_decode_tokens` | `{req_id: [draft_id]}`，长度 0/1 |
| `logits_indices` / `target_logits_indices` | `[sum(1+draft)]` / `[sum(draft)]` |
| target logits | `[sum(1+draft), vocab/tp]` |
| `sampled_token_ids` | `[B, 2]` |
| MTP 输入 hidden | `[T, hc_mult*H=16384]` |
| MTP 层内部流 | `[T_pad, 4, 4096]` |
| MTP 输出 logits | `[B, vocab/tp]` |
| draft token ids | `[B, 1]` |
