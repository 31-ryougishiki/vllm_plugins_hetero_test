# 推理细节 01：对称 P 前向（DP4TP4 / EP16）

本文件描述对称基线阶段的 P 端模型前向路径。

## 0. 模型配置关键值

`DeepSeek-V4-Flash-w8a8-mtp/config.json`：

| 字段 | 值 |
|---|---|
| `architectures` | `DeepseekV4ForCausalLM` |
| `hidden_size` | 4096 |
| `num_hidden_layers` | 43 |
| `num_attention_heads` | 64 |
| `num_key_value_heads` | 1 |
| `head_dim` | 512 |
| `qk_rope_head_dim` | 64 |
| `q_lora_rank` / `o_lora_rank` | 1024 / 1024 |
| `n_routed_experts` | 256 |
| `num_experts_per_tok` | 6 |
| `n_shared_experts` | 1 |
| `moe_intermediate_size` | 2048 |
| `vocab_size` | 129280 |
| `num_nextn_predict_layers` | 1 |
| `hc_mult` | 4 |

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| `AscendDeepseekV4ForCausalLM.forward` | `origin_0.23.0/vllm-ascend/vllm_ascend/models/deepseek_v4.py:1263-1271` |
| `compute_logits` | `deepseek_v4.py:1273-1278` |
| `DeepseekV4Model.forward` | `deepseek_v4.py:1101-1167` |
| 输入 embedding | `deepseek_v4.py:1089-1090,1108-1113` |
| 43 层循环 | `deepseek_v4.py:1133-1134` |
| hc_head 与 final norm | `deepseek_v4.py:1164-1166` |
| `DeepseekV2DecoderLayer` 构造 | `deepseek_v4.py:1042-1045` |
| `DeepseekV4Attention.forward` | `deepseek_v4.py:902-...` |
| `DeepseekV4MoE.forward` | `deepseek_v4.py:460-...` |
| 插件 MoE forward patch | `vllm_plugins/.../deepseekv4/vllm_ascend/models/patch_deepseek_v4.py:163-...` |
| 插件 attention init patch | `patch_deepseek_v4.py:238-...` |

## 2. 进程与线程

- 本次前向只涉及被选中的 P EngineCoreProc → P ITSNPUWorker 子进程；
- 每个 TP rank 的 worker 只执行自己分片的前向，输出经 response MQ 回到 executor。

## 3. HTTP 请求

无模型内 HTTP；请求已在公共链进入 EngineCore。

## 4. 环境变量

`VLLM_ASCEND_ENABLE_FLASHCOMM1=1`、`VLLM_ITS_DEEPSEEK_V4=1`、
`--additional-config` 的 `enable_dsa_cp=true`、`enable_shared_expert_dp=true`。

## 5. 前向调用链

```text
NPUModelRunner._model_forward
  → self.model(input_ids, positions, intermediate_tensors, inputs_embeds)
    AscendDeepseekV4ForCausalLM.forward
      → DeepseekV4Model.forward
          ├─ first rank: embed_input_ids → hidden_states
          ├─ hidden_states.unsqueeze(1).repeat(1, hc_mult=4, 1)
          ├─ for layer in 43 layers:
          │    layer(positions, hidden_states, residual, ...)
          │      ├─ input layernorm
          │      ├─ DeepseekV4Attention.forward
          │      │    MLA/KV 压缩 → RoPE → DSA 计算
          │      ├─ post attention norm
          │      └─ DeepseekV4MoE.forward
          │           router top-k=6 → experts → All-to-All
          ├─ FlashComm1 时 all_gather hidden states，存 _mtp_hidden_buffer
          └─ hc_head + norm
      → compute_logits（采样前）
```

## 6. 对称 TP4 / EP16 的切分

| 组件 | 每个 TP rank |
|---|---|
| attention heads | `64 / 4 = 16`（DSA metadata） |
| wq_b（DSA-CP 开） | Replicated：每 rank 先持有完整 64×512 输出，restore 后切成 16 heads |
| wq_b（DSA-CP 关） | ColumnParallel：每 rank 输出 `[T,16,512]` |
| KV heads | 1（共享） |
| q_lora 输出 | `[T,1024]`（Replicated） |
| o_proj 输入 | DSA-CP restore 后 `[T,16,512]`，即 8192 维 |
| wo_a 输出 | TP4 每 rank 2048（全量 8192）；DSA 3D 每 rank `[2,4096,1024]` |
| wo_b 输入 | TP4 每 rank 2048 |
| 256 routed experts | `256 / 16 = 16` 个/rank（EP=TP×DP=16） |
| top-k experts | 每 token 从 256 中选 6，经 EP all-to-all |
| 共享 expert | 按 `enable_shared_expert_dp=true` 在 DP 间共享 |
| 压缩层状态 | c4 层 state_dim=2048；c128 层 state_dim=1024（`deepseek_v4.py:617-659`） |

## 7. 对称 P 与 D 的差异

- D TP1 时所有 heads（64）在单卡，MoE EP=16（16 D DP×TP1），无 TP 切分；
- 见 `03_decode_d_forward.md`。

## 8. 不确定点

- FlashComm1 是否实际开启依赖 token 数>1000 等运行时条件（`patch_hetero_tp.py:100-117`）；
- DSA-CP 是否开启由 Ascend 运行时配置决定，影响 wq_b 是 Replicated 还是 ColumnParallel；
- `mix_placement` 影响共享专家是否并入 256 专家 FusedMoE；
- 图编译/ACLGraph 可能把上述 Python 路径替换为捕获图；
- 43 层中每层的具体 attention 后端由 metadata 运行时选择。
