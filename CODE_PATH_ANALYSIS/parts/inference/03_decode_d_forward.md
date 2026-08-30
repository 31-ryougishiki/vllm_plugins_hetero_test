# 推理细节 03：D 拉 KV 后 decode 前向（DP16TP1）

描述 D 端请求等待远程 KV 就绪后的实际 decode 前向路径。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| D 请求状态提升 | `origin_0.23.0/vllm/vllm/v1/core/sched/scheduler.py:2188-2203` |
| model_runner 无前向走 KV connector | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/model_runner_v1.py:2060-2090` |
| 有前向时获取 KV connector output | `model_runner_v1.py:2311-2316` |
| `_model_forward` | `model_runner_v1.py:2320,2834-2874` |
| `AscendDeepseekV4ForCausalLM.forward` | `origin_0.23.0/vllm-ascend/vllm_ascend/models/deepseek_v4.py:1263-1271` |
| `DeepseekV4Model.forward` | `deepseek_v4.py:1101-1167` |
| D TP1 的 attention/MoE | `deepseek_v4.py:902-...,460-...` |
| Mooncake start_load_kv | `origin_0.23.0/vllm-ascend/vllm_ascend/distributed/kv_transfer/kv_p2p/mooncake_hybrid_connector.py:1770-...` |
| patch start_load_kv | `vllm_plugins/.../deepseekv4/vllm_ascend/distributed/kv_transfer/patch_hetero_mooncake.py:455-565` |
| patch transfer | `patch_hetero_mooncake.py:673-801` |

## 2. 进程与线程

- D EngineCoreProc：scheduler 调度 + connector scheduler；
- D ITSNPUWorker：connector worker + `KVCacheRecvingThread` 异步传输线程；
- 拉 KV 与模型前向在 worker 进程内先后衔接。

## 3. HTTP 请求

D 收到的请求携带 `kv_transfer_params`；本阶段没有新的 HTTP。

## 4. 环境变量

`kv_transfer_config.kv_role=kv_consumer`、`DECODE_KV_PORT=36200`、
`DECODE_ENGINE_ID=1`、`ASCEND_CONNECT_TIMEOUT`、`MC_TRANSFER_TIMEOUT`。

## 5. 状态与调用链

```text
D 请求进入 scheduler：
  → WAITING_FOR_REMOTE_KVS（异步 load）
  → worker connector.start_load_kv 完成并上报 finished_recving
  → scheduler._try_promote_blocked_waiting_request
      status → WAITING（或 PREEMPTED）
  → 下一 engine step：scheduler.schedule 把请求放入 running
  → model_runner.execute_model
      有实际 tokens 时不再走 kv_connector_no_forward；
      maybe_get_kv_connector_output 包裹前向
      _model_forward → AscendDeepseekV4ForCausalLM.forward
        DeepseekV4Model.forward
          hidden = embed(input_ids)   # prompt 已包含 P 的 KV 对应 prefix？
          for layer in 43:
            DeepseekV4Attention.forward（TP1：64 heads 本地）
            DeepseekV4MoE.forward（EP=16：每 D rank 16 experts）
          hc_head + norm
        compute_logits → 采样下一个 token
```

说明：D TP1 时没有 TP 切分；`num_key_value_heads=1` 的 KV 使用本地 KV cache，
远程部分由 Mooncake 在 scheduler 层完成拉取并计入 `num_computed_tokens`。

## 6. D TP1 与 P TP4 的前向差异

| 项 | P TP4/异构 | D TP1 |
|---|---|---|
| attention heads | 16 / 32,16,16 | 64 |
| o_proj | TP 切分/异构恢复 | 无切分 |
| MoE EP | 16 或 15 | 16（16 DP × TP1） |
| padding/AllGather | LCM 或 TP 对齐 | 无 TP padding |
| KV | producer，写 KV | consumer，拉 KV 后本地续推 |
| `patch_deepseek_v4` 异构分支 | 执行（S1 后） | `is_heterogeneous_tp=False`，MLP/MoE init 修正、attention head 重算均跳过 |
| MoE TP reduce | 按 SP/异构分支 | TP1 不触发 `maybe_all_reduce_tensor_model_parallel` |

## 7. 不确定点

- 本文按 D DP16TP1 **homogeneous**（`is_heterogeneous_tp=False`）分析；若 D 侧也被配置
  `heterogeneous_dp_config`，`patch_deepseek_v4.py` 的 ratios 分支会执行，但 TP1 下数值不变；
- D 端 `_prefill_tp_size` 读自 `kv_transfer_config.extra_config["prefill"]["tp_size"]`，
  静态无法确认 P 异构后该值填 3 还是 4；MLA 下 `tp_num_need_pulls` 恒 1，影响较小；
- `use_hybrid` 为 false 时走非 hybrid KV 传输路径；
- 远程 KV 失败时 `invalid_block_ids` 会改变可用 tokens，本文未展开完整错误处理；
- D 的 MoE/attention 后端选择仍取决于 NPU 图编译。
