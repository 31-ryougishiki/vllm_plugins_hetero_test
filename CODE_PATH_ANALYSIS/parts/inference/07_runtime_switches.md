# 推理细节 07：可由测试脚本确定/需运行时确认的开关

结论：多数此前标为“运行时开关不确定”的项，其实可以由 `vllm_plugins_hetero_test`
的 launch 脚本环境变量/CLI/additional_config，结合 `origin_0.23.0` 的默认值静态判定。
下表给出 P/D 两侧的判定结果与证据。

## 1. 脚本可直接判定的开关

| 开关 | P（launch_prefill_hetero_test.sh） | D（decode/launch_decode_pd.sh） | 源码判定依据 |
|---|---|---|---|
| `VLLM_ITS_DEEPSEEK_V4` | 1（`:98`） | 1（`:102`） | `zero_interrupt/common/constants.py:51-66` |
| `VLLM_CUSTOM_PATCHES` | `zero_interrupt`（`:95`） | `zero_interrupt`（`:99`） | 插件入口 |
| `enable_dsa_cp` | true（`--additional-config :155`） | **false**（未在 additional_config 设置；默认 false） | `vllm_ascend/utils.py:1515-1535` |
| `VLLM_ASCEND_ENABLE_FLASHCOMM1` | 1（`:87`） | **未设置 → 默认 0** | `vllm_ascend/envs.py:75`；`ascend_config.py:84-89` |
| `enable_flashcomm2` | **false**（未设置 → 默认 0） | false（未设置 → 默认 0） | `vllm_ascend/envs.py:80`；`utils.py:1288-1290` |
| `enable_shared_expert_dp` | true（additional_config `:155`，且 TP4>1） | **false**（未设置且 TP1，不满足 `tensor_parallel_size>1`） | `ascend_config.py:114-118` |
| `mix_placement` | **false**（未设置，默认 false） | false（未设置，默认 false） | `ascend_config.py:341-342` |
| hybrid KV manager | true（`--no-disable-hybrid-kv-cache-manager :142`） | true（`:144`） | `platform.py:316` / connector `disable_hybrid_kv_cache_manager` |
| `enforce_eager` | true（P `:154`） | **未显式设置**（D 无 `--enforce-eager`，且 `compilation_config.cudagraph_mode=FULL_DECODE_ONLY`） | vLLM CLI 与 `ModelConfig.enforce_eager` |
| `async_scheduling` | false（P 未设置） | true（D `:142`） | CLI `--async-scheduling` |
| `enable_sp_by_pass` | **false**（`enforce_eager=true` 导致条件不成立） | 需结合 D 图编译 pass 默认值（见第 3 节） | `ascend_config.py:291-295` |
| `quantization` | `ascend`（P `:153`） | `ascend`（D `:154`） | CLI |
| `VLLM_ASCEND_ENABLE_FUSED_MC2` | 未设置 → 默认 0 | 未设置 → 默认 0 | `envs.py:102` |
| `multistream_overlap_shared_expert` | 未设置 → 默认 false | true（D `:172`） | `ascend_config.py:139` |
| `recompute_scheduler_enable` | 未设置 → 默认 false | true（D `:173`） | `ascend_config.py:142` |
| `enable_npugraph_ex` | 未设置（走平台默认） | true（D `:168`） | D additional_config |
| `enable_static_kernel` | 未设置（走平台默认） | false（D `:169`） | D additional_config |

## 2. 由模型 config 直接确定

`DeepSeek-V4-Flash-w8a8-mtp/config.json`：

| 项 | 值 | 影响 |
|---|---|---|
| `model_type` | `deepseek_v4` | MTP draft 映射为 `DeepSeekV4MTPModel` |
| `index_topk` / `index_n_heads` | 512 / 64 | `enable_dsa_cp()` 的 `has_indexer=true` |
| `n_routed_experts` | 256 | EP15 余数分布、ALLGATHER 判定 |
| `num_experts_per_tok` | 6 | MoE top-k |
| `num_nextn_predict_layers` | 1 | MTP draft 层数 |
| `head_dim` / `qk_rope_head_dim` | 512 / 64 | DSA/MLA shapes |
| `hc_mult` | 4 | hidden stream `[T,4,H]` |

## 3. 仍只能在运行时确定的项

| 项 | 原因 |
|---|---|
| FlashComm1 是否实际激活 SP | P 已设置 env=1，但 `patch_hetero_tp.py:100-117` 还要看 `num_tokens>1000`、`enable_sp()` 与当前 vllm_config 状态 |
| `enable_sp_by_pass`（D 侧） | D 未显式 `--enforce-eager`，取决于 compilation pass `enable_sp` 默认值与平台推断 |
| MoE comm 方法最终选择 | 静态可确定 EP15→ALLGATHER 分支，但 `mc2_tokens_capacity`、quant_type 与 fused 开关影响非整除之外的场景 |
| NPU 图编译捕获的具体 kernel | 需要实跑图 dump/profile |
| 旧 Mooncake 缓存清理时序 | 代码无主动清理，运行时实际内存行为需观测 |
| DC 侧运行时配置 | `FAULT_CODE_CONFIG`、DC 部署版本在测试脚本之外 |

## 4. 对前文不确定点的修正

- 01/02 文档中“DSA-CP 是否开启不确定”应改为：
  **P 开启、D 关闭**（脚本 additional_config 可判定）。
- “`mix_placement` 不确定”应改为：
  **P/D 均为 false**（未设置且默认 false），因此共享专家不并入 256 experts；
  对称 EP16 时每 rank 16 experts，异构 EP15 时 rank0 18/其余 17。
- “`use_hybrid` 不确定”应改为：
  **P/D 均为 true**（`--no-disable-hybrid-kv-cache-manager`），KV 传输走
  `_transfer_kv_cache_all_groups`。
- “D 是否启用 MTP 不确定”应改为：
  脚本静态上 D launch 也带 `--speculative-config method=mtp`，因此 D 会创建
  `AscendEagleProposer`；是否真正产生 draft 还取决于 scheduler 是否有
  `scheduled_spec_decode_tokens`。
