# 推理细节 02：异构 P 前向（DP4TP(3,4,4,4) / EP15）

描述 S1 异构重启后 P 端一次预填充前向的细节分支与张量形状。

## 0. 异构拓扑

| DP | TP | shardings | 本地 heads（64 头按比例） | 全局 rank offset |
|---|---|---|---|---|
| DP0 | 3 | `[2,1,1]` | rank0=32，rank1=16，rank2=16 | 0 |
| DP1 | 4 | uniform | 16/16/16/16 | 3 |
| DP2 | 4 | uniform | 16/16/16/16 | 7 |
| DP3 | 4 | uniform | 16/16/16/16 | 11 |

全局 worker world=15；EP=15。

## 1. 代码行号

| 模块 | 关键位置 |
|---|---|
| forward context 异构分支 | `vllm_plugins/.../deepseekv4/vllm_ascend/patch/patch_hetero_tp.py:143-224` |
| padded length / LCM | `patch_hetero_tp.py:165-180,202-216` |
| MC2 capacity 异构对齐 | `patch_hetero_tp.py:231-263` |
| EP15 非整除 → ALLGATHER | `patch_hetero_tp.py:266-312` |
| linear 比率与 scaffolding | `.../ops/patch_hetero_ascend_linear.py:46-135,188-267,269-405,407-589` |
| linear apply | `patch_hetero_ascend_linear.py:893-...` |
| DSA local heads | `.../attention/patch_deepseek_v4_attention_hetero.py:47-77` |
| metadata 构造 | `patch_deepseek_v4_attention_hetero.py:79-...` |
| o_proj 输入/恢复 | `patch_deepseek_v4_attention_hetero.py:695-774,908-991` |
| DSA CP init | `patch_deepseek_v4_attention_hetero.py:847-906` |
| LCM metadata patch | `patch_deepseek_v4_attention_hetero.py:780-845` |
| MoE 余数分布/通信 | `.../ops/fused_moe/patch_hetero_moe.py:...`（apply 736 起） |
| MoE 前向入口 patch | `.../models/patch_deepseek_v4.py:163-236,539-565` |

## 2. 进程与线程

与对称前向相同：EngineCoreProc → ITSNPUWorker；差异是 DP0 只有 3 个 worker，
其余 DP 各 4 个 worker。

## 3. HTTP 请求

无模型内 HTTP。

## 4. 环境变量

`VLLM_ITS_DEEPSEEK_V4=1`、`VLLM_ASCEND_ENABLE_FLASHCOMM1=1`、
`enable_dsa_cp=true`、策略注入的 `zero_interrupt_config`/`heterogeneous_dp_config`。

## 5. 前向调用链

```text
NPUModelRunner.execute_model
  → patch_hetero_tp 设置的 forward context 生效：
      per_dp_tp_sizes=[3,4,4,4]
      per_dp_padded_lengths 按各自 tp 向上取整
      padded_num_tokens = ceil(max_tokens_across_dp / lcm(3,4)) * 12
      flash_comm_v1/v2 时 padded_length 对齐 lcm(3,4)
  → _model_forward → AscendDeepseekV4ForCausalLM.forward
      DeepseekV4Model.forward（层循环与对称一致）
      layer:
        Attention（patch_deepseek_v4_attention_hetero）
          DP0: n_local_heads 32/16/16；metadata 用异构 heads
          o_proj_input: [num_tokens, n_local_heads, 512]
          padding 行清零 → rope → _forward_o_proj
          restore_tp_head_layout 按 tp_sharding_ratios 恢复
        MoE（patch_hetero_moe + patch_deepseek_v4 MoE forward）
          EP=15，256 experts：rank0 18，rank1-14 17
          num_experts % ep != 0 → MoECommType.ALLGATHER
          top-k=6 路由、余数 dispatch、All-to-AllV 余数处理
```

### 5.1 与 model runner / 模型 patch 的衔接

- `patch_hetero_model_runner.py`：
  - DP metadata all_reduce 改用 EP group，并逐 DP 除以各自 tp_size（:24-99）；
  - profile 时把 `max_num_tokens` 对齐到 LCM(3,4)=12 的倍数（:102-123）。
- `patch_deepseek_v4.py`：
  - Attention init 按 ratios 重算 `n_local_heads/n_local_groups` 并写回 DSA 引用（:238-310）；
  - MoE init 按余数分布重算 `n_local_physical_experts`/start/end（:124-160）；
  - MoE forward 在“异构且未被 FlashComm SP 切分”时先 `sequence_parallel_chunk`，
    输出再 all_gather/reduce（:163-235）；
  - MLP 的 shared_experts 在异构下强制 `is_sequence_parallel=True`（:94-121）。

## 6. 张量形状/切分表

| 项 | 对称 TP4 | 异构 DP0 TP3 | 异构 DP1-3 TP4 |
|---|---|---|---|
| 本地 q heads | 16 | 32 / 16 / 16 | 16 |
| o_proj 输入宽 | 16×512=8192 | 32×512=16384 / 8192 / 8192 | 8192 |
| 每 rank experts | 16 | rank0 18，其余 17（全局 EP15） | 17/18 分布 |
| padded_num_tokens 对齐 | TP=4 | LCM(3,4,4,4)=12 | 12 |
| MoE comm | MC2/ALLTOALL | 256%15≠0 → ALLGATHER | ALLGATHER |
| 权重 sharding | 均匀 | `[2,1,1]` | 均匀 |

## 7. 对称 vs 异构路径差异

| 阶段 | 对称 | 异构 |
|---|---|---|
| forward context | `per_dp_*` 为 None | 注入 per-DP sizes/lengths |
| padding | 按 tp_world_size | 按 LCM(3,4)=12 |
| linear 初始化/加载 | 标准 | ratio scaffolding / `_tp_sharding_ratios` |
| attention metadata | 均匀 heads | 32/16/16 且 LCM metadata |
| MoE | 256%16=0 | 256%15≠0 → ALLGATHER + 余数分布 |
| o_proj | 标准 TP | ratio-sharded restore |

## 8. 不确定点

- DP0 rank0 的 32 heads 依据 `[2,1,1]` 比例静态推导，实际由
  `get_tp_partition_size`/`get_current_tp_sharding_ratios` 在运行时确认；
- **DSA-CP 是否实际开启**由 Ascend 运行时配置决定；关闭时 wq_b 走 ColumnParallel，
  attn_sink 走 TP 切分，异构路径会进入另一个分支；
- **`mix_placement`** 影响共享专家是否并入 FusedMoE：若为 true，专家数按 257
  参与余数分布，不再是 256/15 的 rank0 18/其余 17；
- EP 组内 rank 顺序（DP-major/TP-major）由运行时并行组构建决定，静态只能依据
  `patch_hetero_moe.py:75-108` 的反推逻辑判断；
- FlashComm1/FlashComm2/sp_by_pass 是否开启会改变 chunk/pad/AllGather input 路径；
- `forward_context.num_tokens` 与 `padded_num_tokens` 在 SP 路径下的口径需要实跑确认；
- `MoECommType` 还受 `mc2_tokens_capacity` 与 quant_type 影响；
- 图编译可能缓存不同形状分支，实际命中需实跑图 dump。
