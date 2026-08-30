# 推理细节 00：公共请求链

本文件是推理细节子目录的公共链说明；P/D 前向、KV 传输、MTP 等细节见同目录其他文档。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| `/v1/completions` 路由 | `origin_0.23.0/vllm/vllm/entrypoints/openai/completion/api_router.py:34-46` |
| OpenAI serving 入口 | `completion/serving.py:110-126` |
| `engine_client.generate` | `completion/serving.py:204` |
| `AsyncLLM.generate` | `origin_0.23.0/vllm/vllm/v1/engine/async_llm.py:524` |
| `AsyncLLM.add_request` / `_add_request` | `async_llm.py:280,400-412` |
| DPLB 发送 ADD | `origin_0.23.0/vllm/vllm/v1/engine/core_client.py:1344-1357` |
| busy loop 输入处理 | `origin_0.23.0/vllm/vllm/v1/engine/core.py:1223-1262` |
| ZMQ input 接收 | `core.py:1448-1543` |
| step_fn 选择 | `core.py:192-219`（batch_queue=None → `step`，否则 `step_with_batch_queue`） |
| engine step | `core.py:1264-1281` |
| `EngineCore.step` | `core.py:443-472` |
| executor 广播 execute_model | `origin_0.23.0/vllm/vllm/v1/executor/multiproc_executor.py:307-317,340-374` |
| worker 循环 | `multiproc_executor.py:879` |
| NPU worker execute_model | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/worker.py:611-647` |
| NPUModelRunner execute_model | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/model_runner_v1.py:1950` |
| `_model_forward` | `model_runner_v1.py:2320,2834-2874` |
| 插件替换的 busy loop | `vllm_plugins/.../deepseekv4/vllm/v1/engine/engine_core_patch.py:255-401,1004-1036` |
| 插件 executor 分派 | `vllm_plugins/.../its_multiproc_executor.py:176-...`（collective_rpc 继承） |

## 2. 进程与线程

一次请求跨：

```text
测试脚本 python（临时）
→ proxy（若经代理）：FastAPI handler + generate_stream 协程 + httpx
→ API server/AsyncLLM 前端进程
→ EngineCoreProc 进程
→ ITSNPUWorker 子进程 × 本地 world_size
```

ZMQ/MessageQueue 通道：

- 前端 → EngineCore：ZMQ ROUTER/DEALER（`core_client.py:488-576`）；
- EngineCore → worker：`rpc_broadcast_mq` MessageQueue（`multiproc_executor.py:51-61,374`）；
- worker → executor：`worker_response_mq`（`multiproc_executor.py:570-591,926-939`）；
- EngineCore → 前端：output ZMQ（`core.py:1270-1271`）。

## 3. HTTP 请求

| 阶段 | 端点/协议 |
|---|---|
| 客户端 | `POST /v1/completions`，OpenAI JSON |
| proxy→P | 同上 + `max_tokens=1` + `kv_transfer_params.do_remote_decode=true` |
| P→proxy | JSON，含 `kv_transfer_params` |
| proxy→D | 原请求 + P 的 `kv_transfer_params` |
| D→客户端 | SSE 流 / JSON |

## 4. 环境变量

见 `03_baseline_request.md`；执行期关键变量：
`VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS`、`VLLM_RPC_TIMEOUT`、
`kv_transfer_config`、`VLLM_ITS_DEEPSEEK_V4=1`。

## 5. 函数调用链

```text
POST /v1/completions
  → create_completion(api_router)
    → OpenAIServingCompletion.create_completion
      → _create_completion
        → engine_client.generate
          AsyncLLM.generate
            → add_request → _add_request
              InputProcessor.process_inputs
              OutputProcessor.add_request
              engine_core.add_request_async
                DPLBAsyncMPClient.add_request_async
                  get_core_engine_for_request
                  _send_input(EngineCoreRequestType.ADD)
                    ZMQ → EngineCoreProc input_queue
EngineCoreProc.run_busy_loop（插件已 patch）
  → _process_input_queue
    → _handle_client_request(ADD) → scheduler.add_request
  → _process_engine_step
    → step_fn = EngineCore.step（或 step_with_batch_queue）
        scheduler_output = scheduler.schedule()
        model_executor.execute_model(scheduler_output, non_block=True)
          ITSMultiprocExecutor 继承 MultiprocExecutor.execute_model
            collective_rpc("execute_model")
              rpc_broadcast_mq.enqueue(...)
WorkerProc.worker_busy_loop
  → ITSNPUWorker.execute_model
    NPUWorker.execute_model
      → model_runner.execute_model
        → 输入准备/attention metadata
        → maybe_get_kv_connector_output / kv_connector_no_forward
        → _model_forward
          → AscendDeepseekV4ForCausalLM.forward
        → sampler → ModelRunnerOutput
  → enqueue_output → worker_response_mq
Executor.collective_rpc 收到输出
  → EngineCore.step 返回
  → scheduler.update_from_output
  → EngineCoreOutputs → output_queue(ZMQ)
AsyncLLM.output_handler
  → OutputProcessor → RequestOutput
  → OpenAI serving 组装 CompletionResponse / SSE
```

插件对公共链的修改点：

| 位置 | patch |
|---|---|
| `EngineCoreProc.has_work` | `engine_core_patch.py:133-149,1014-1016`：暂停时返回 False 并清 batch_queue |
| `EngineCoreProc._handle_shutdown` | `engine_core_patch.py:255-402,1010-1012`：策略消费/重启/engine_id 轮换 |
| `EngineCoreProc.step` | `engine_core_patch.py:406-466,1026-1028`：world_size=0/paused 直接返回；None 输出不喂 scheduler |
| `EngineCoreProc.step_with_batch_queue` | `engine_core_patch.py:468-634,1030-1036`：故障容错 |
| DPLB 引擎选择 | `core_client_patch.py:49-93,99-140`：过滤 world_size=0 的空转 engine |
| `MultiprocExecutor.collective_rpc` | `its_multiproc_executor.py:176-249`：worker FAILURE/超时返回 None，不直接抛异常 |
| `WorkerProc` | 替换为 `ITSNPUWorker`（继承 AscendWorkerProc，busy loop 仍来自上游 WorkerProc） |
| worker `execute_model` 容错 | `its_multiproc_executor.py:2718-2734`：all_reduce/连接错误返回 None |
| NPUModelRunner DP 元数据同步 | `patch_hetero_model_runner.py:24-99,135-139`：异构改走 EP group，逐 DP 除 tp_size |
| NPUModelRunner profile_run | `patch_hetero_model_runner.py:102-123,140`：max_num_tokens 对齐 LCM(tp_sizes) |
| Ascend forward context | `patch_hetero_tp.py:38-228,231-312,315-365`：per-DP sizes、LCM pad、MoE 回退 ALLGATHER |

## 6. 不确定点

- `step_fn` 选择 `step` 或 `step_with_batch_queue` 由 `max_concurrent_batches` 决定
  （`core.py:192-219`）；默认 PP1 且未显式设置时通常为 `step`，静态无法唯一判定；
- DPLB 引擎选择由 `get_core_engine_for_request` 的负载均衡逻辑决定，单请求时仍可能
  受历史统计影响；HTTP header `X-data-parallel-rank` 可由外部 router 注入；
- 非 stream 与 stream 在 `serving.py:224` 后分叉，engine 侧主链一致；
- NPU 算子/图编译层的具体 kernel 选择需要运行时图 dump。
