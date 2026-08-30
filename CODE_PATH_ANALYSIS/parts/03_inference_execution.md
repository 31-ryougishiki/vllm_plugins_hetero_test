# 阶段 03 补充：正常请求的推理执行路径（总览/索引）

覆盖 `send_pd_request.py` 发出请求后的三种推理链：
A. 基线 PD 代理链（P 预填充 → KV 转 D → D 续推）；
B. 异构重启后的 PD 推理链（P 异构前向 + D 按新元数据拉 KV）；
C. D 单机直连推理链（P7/P8）。

详细推理细节已下沉到 `inference/` 子目录：

| 子文档 | 内容 |
|---|---|
| `inference/00_common_request_chain.md` | HTTP→EngineCore→worker→模型输出的公共请求链 |
| `inference/01_symmetric_p_forward.md` | 对称 P DP4TP4/EP16 的前向、形状与切分 |
| `inference/02_hetero_p_forward.md` | 异构 P DP4TP(3,4,4,4)/EP15 的前向分支与张量形状 |
| `inference/03_decode_d_forward.md` | D TP1 拉 KV 后的 decode 前向 |
| `inference/04_kv_transfer_timeline.md` | Mooncake 握手/拉取/线程时序 |
| `inference/05_scheduler_kv_state_machine.md` | scheduler↔connector↔model_runner 状态迁移 |
| `inference/06_mtp_path.md` | MTP drafter/proposer 在 prefill/decode 的路径 |
| `inference/07_runtime_switches.md` | 测试脚本可判定的环境/配置开关与仍需运行时确认的项 |

基线源码引用：`origin_0.23.0/vllm`、`origin_0.23.0/vllm-ascend`；
实际运行文件为插件替换后的 `ITSMultiprocExecutor`/`ITSNPUWorker` 与 hetero patch。

## 1. 代码行号（关键入口）

| 步骤 | 文件:行号 |
|---|---|
| OpenAI `/v1/completions` 路由 | `vllm/entrypoints/openai/completion/api_router.py:34-46` |
| `OpenAIServingCompletion.create_completion` | `completion/serving.py:110-126` |
| `_create_completion` | `completion/serving.py:128-...` |
| 调用 `engine_client.generate` | `completion/serving.py:204` |
| `AsyncLLM.generate` | `vllm/v1/engine/async_llm.py:524` |
| `AsyncLLM.add_request` | `async_llm.py:280` |
| `_add_request` → `engine_core.add_request_async` | `async_llm.py:400-412` |
| DPLB 客户端发送请求 | `vllm/v1/engine/core_client.py:1344-1357` |
| EngineCore 输入队列处理 | `vllm/v1/engine/core.py:1233-1262` |
| `_process_engine_step` | `core.py:1264-1281` |
| `EngineCore.step` | `core.py:443-455` |
| `scheduler.schedule` | `core.py:454` |
| executor `execute_model` | `vllm/v1/executor/multiproc_executor.py:307-317` |
| `collective_rpc` | `multiproc_executor.py:340-374` |
| WorkerProc `worker_busy_loop` | `multiproc_executor.py:879` |
| NPUWorker `execute_model` | `vllm_ascend/worker/worker.py:611-647` |
| NPUModelRunner `execute_model` | `vllm_ascend/worker/model_runner_v1.py:1950-...` |
| KV connector no-forward（D 等远程 KV） | `model_runner_v1.py:2075,2090` |
| `_model_forward` | `model_runner_v1.py:2320,2834-2874` |
| DeepSeek-V4 模型 forward | `vllm_ascend/models/deepseek_v4.py:1101,1263` |
| P 侧 KV connector `request_finished` 生成 kv_transfer_params | `vllm_ascend/distributed/kv_transfer/kv_p2p/mooncake_hybrid_connector.py:1428-1454` |
| D 侧 `start_load_kv` | `mooncake_hybrid_connector.py:1133-1136,1770` |
| 插件 Mooncake 补丁函数 | `vllm_plugins/.../deepseekv4/vllm_ascend/distributed/kv_transfer/patch_hetero_mooncake.py:399-441,455-565,630-670,673-801` |

## 2. 进程与线程

一次经代理的请求跨 3 类进程：

| 进程 | 角色 |
|---|---|
| 测试脚本临时 python 进程 | 发起 HTTP（结束即退出） |
| PD proxy 进程 | FastAPI handler + `generate_stream` 协程 + httpx 流式客户端 |
| P 前端/API server 进程 | OpenAI serving → AsyncLLM |
| P EngineCoreProc | scheduler、executor、KV connector scheduler |
| P ITSNPUWorker 进程 | 模型预填充，返回 logits/KV |
| D 前端/API server 进程 | 接收带 `kv_transfer_params` 的续推请求 |
| D EngineCoreProc | scheduler 标记 WAITING_FOR_REMOTE_KVS、KV connector 等待/触发传输 |
| D ITSNPUWorker 进程 | 远程 KV 就绪后执行 decode 前向 |

D 单机直连链不经过 proxy 与 P，只有 D 的 3 类进程。

## 3. HTTP 请求

- 测试脚本 → proxy/D：`POST /v1/completions`，body 见 `03_baseline_request.md`。
- proxy → P：`max_tokens=1`，并注入 `kv_transfer_params={do_remote_decode:true,...}`。
- P → proxy：响应 JSON 中携带 `kv_transfer_params`（`do_remote_prefill=true`、remote_host/port、engine_id、block_ids 等）。
- proxy → D：原请求 + P 返回的 `kv_transfer_params`。
- D → proxy → 客户端：SSE 流，逐 chunk 文本/stop_reason；`recomputed` 时 proxy 重新走 P→D。

## 4. 环境变量

- 请求侧：`PROXY_URL`、`PROMPT`、`MAX_TOKENS`、`REQUEST_TEMPERATURE=0.0`、`REQUEST_SEED=1024`；
- P/D 服务侧：`VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=30000`、`VLLM_RPC_TIMEOUT`、
  `kv_transfer_config`（kv_role、kv_port、engine_id、prefill/decode dp/tp 描述）、
  `VLLM_ITS_DEEPSEEK_V4=1`（决定 hetero patch 分支）。

## 5. 函数调用链

### 5.1 公共链：HTTP → EngineCore → worker → 模型

```text
POST /v1/completions
  → create_completion（api_router）
    → OpenAIServingCompletion.create_completion
      → _create_completion
        → engine_client.generate
          AsyncLLM.generate
            → add_request → _add_request
              InputProcessor 处理 prompt
              OutputProcessor.add_request
              engine_core.add_request_async
                DPLBAsyncMPClient.add_request_async
                  get_core_engine_for_request → 选择 DP engine
                  ZMQ 发送 EngineCoreRequestType.ADD
EngineCoreProc.run_busy_loop（已被插件 patch）
  → _process_input_queue
    → _handle_client_request（ADD 进入 scheduler）
  → _process_engine_step
    → step_fn = EngineCore.step
        scheduler_output = scheduler.schedule()
        future = model_executor.execute_model(scheduler_output, non_block=True)
          ITSMultiprocExecutor 继承的 MultiprocExecutor.execute_model
            → collective_rpc("execute_model")
            → MessageQueue 广播 scheduler_output 到 workers
WorkerProc.worker_busy_loop
  → worker.execute_model(scheduler_output)
    NPUWorker.execute_model
      → self.model_runner.execute_model
        → 输入准备/attention metadata/forward context
        → _model_forward
          → self.model(input_ids, positions, ...)
            AscendDeepseekV4ForCausalLM.forward
              → DeepseekV4Model.forward → 各层
              → compute_logits
        → sampler / 输出
  → worker response MQ → executor collective_rpc 返回
  → scheduler.update_from_output / EngineCoreOutputs
  → ZMQ output → AsyncLLM.output_handler → RequestOutput
  → OpenAI serving 组装 CompletionResponse/SSE 返回
```

### 5.2 A. 基线 PD 代理链

```text
send_pd_request.py → proxy /v1/completions
  → _handle_completions → _handle_select_instance
      P 首跳（max_tokens=1 + do_remote_decode=true）
P: 上述公共链执行 1-token 预填充
   scheduler.update_from_output 时 MooncakeHybridConnector.request_finished
   构建 do_remote_prefill=true 的 kv_transfer_params
   → RequestOutput.kv_transfer_params → CompletionResponse JSON
proxy: 取出 kv_transfer_params，注入原请求，转发 D
D: 请求进入 scheduler，KV connector 将请求标记 WAITING_FOR_REMOTE_KVS
   scheduler 再次 step 时：
     model_runner.execute_model
       → kv_connector_no_forward
         → MooncakeConnectorScheduler.start_load_kv
           → MooncakeConnectorWorker.start_load_kv
             KVCacheRecvingThread 按 (engine_id, handshake_port)
             从 P 拉取远程 KV blocks
   KV 就绪后正常执行 decode 前向
   → 输出流回 proxy → send_pd_request 保存 JSON
```

### 5.3 B. 异构重启后的 PD 推理链

与 A 相同，但前向命中以下 hetero patch：

- P 侧：
  - `patch_hetero_tp.py`：发布 `per_dp_tp_sizes=[3,4,4,4]`、LCM 对齐 padding、EP=15 下 AllGather；
  - `patch_hetero_ascend_linear.py`：DP0 tp=3 权重 scaffolding 与 ratio-aware loader；
  - `patch_deepseek_v4_attention_hetero.py`：DSA-CP 非对称 head 32/16/16、o_proj 恢复；
  - `patch_hetero_moe.py`：256 experts 余数分布与 All2AllV 余数 dispatch；
  - `patch_hetero_mooncake.py`：累计端口 offset 0/3/7/11、绝对 handshake_port。
- D 侧：
  - `patch_hetero_mooncake.py` 的 `_patched_get_remote_host_info_by_port`
    优先按绝对 handshake_port 匹配；缺 `(engine_id, handshake_port)` 缓存时
    `_patched_get_remote_metadata` 重新拉元数据，再走 `_transfer_kv_cache_all_groups`。
- P 重启时 engine_id 已轮换（见 `05_restart_recovery.md`），D 因此以新 key 拉取，
  避免旧地址传输。

### 5.4 C. D 单机直连推理链（P7/P8）

```text
send_pd_request.py --url http://127.0.0.1:9100/v1/completions
  → D 的 OpenAI/AsyncLLM/EngineCore/worker 公共链
  → 请求不带 kv_transfer_params：D 本地完成 prompt 预填充与 decode
  → 不经过 proxy、不经过 P、不执行 PD KV 传输
```

## 6. 在 8 条路径中的差异

| 路径 | 请求出口 | P/D KV 链路 | 前向分支 |
|---|---|---|---|
| P1/P2 基线 | proxy | 是（对称 P→D） | 对称 P / D TP1 |
| P1/P2 复测 | proxy | 是（异构 P→D） | P 异构 / D TP1 |
| P3/P4 基线 | proxy | 是（对称 P→16 D） | 对称 |
| P3/P4 复测 | proxy | 是（对称 P→15 D） | 对称 |
| P5/P6 复测 | proxy | 是（恢复后对称 P→16 D） | 对称 |
| P7 基线/复测 | 直连 D | 否 | D 本地前向 |
| P8 复测 | 直连 D | 否 | D 本地前向 |

## 7. 不确定点

- `step_fn` 是 `step` 还是 `step_with_batch_queue` 由 scheduler async 配置决定；
  两条函数都已被插件 patch，文档按非 async 主链描述。
- D 侧 WAITING_FOR_REMOTE_KVS 与 KV transfer 线程的实际时序未实跑验证；
- recomputed 分支的“正确文本 + 无关数据”拼接问题由 warmup 吸收，但静态无法
  证明首次请求不会触发；
- 模型前向内部具体算子（DSA/MoE 的自定义算子）以 NPU 运行时图编译结果为准。
