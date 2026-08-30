# 阶段 01 补充：拉起脚本后推理服务的启动路径

覆盖从 `python3 -m vllm.entrypoints.openai.api_server` 到 `/health` 就绪的完整 vLLM v1
启动链，以及插件在启动链中的挂载点。进程布局、环境变量、插件 patch 清单见
`01_install_launch.md`。

基线说明：vLLM / vllm-ascend 源码引用使用 `origin_0.23.0/vllm` 与
`origin_0.23.0/vllm-ascend`；插件代码引用使用 `vllm_plugins`。
注意：实际运行的 `MultiprocExecutor`/`WorkerProc` 已被插件替换为
`ITSMultiprocExecutor`/`ITSNPUWorker`。

## 1. 代码行号（关键入口）

| 步骤 | 文件:行号 |
|---|---|
| `python -m vllm.entrypoints.openai.api_server` 的 main | `origin_0.23.0/vllm/vllm/entrypoints/openai/api_server.py`（模块入口） |
| `run_server` | `api_server.py:652-665` |
| `run_server_worker` | `api_server.py:668-684` |
| `build_async_engine_client` | `api_server.py:77-104` |
| `create_engine_config` | `api_server.py:123` |
| `AsyncLLM.from_vllm_config` | `api_server.py:135-144` |
| `AsyncLLM.__init__` | `vllm/v1/engine/async_llm.py:73-153` |
| `EngineCoreClient.make_async_mp_client` | `vllm/v1/engine/core_client.py:108-131` |
| DP 内部 LB 分支 | `core_client.py:125-130` |
| `MPClient.__init__`（ZMQ + 启动 EngineCore 进程） | `core_client.py:477-576` |
| `launch_core_engines` | `vllm/v1/engine/utils.py:1049-1187` |
| DP Coordinator（rank0） | `utils.py:1083-1104` |
| EngineCoreProc 启动等待 | `utils.py:1189-1199` |
| `EngineCore.__init__` | `vllm/v1/engine/core.py:95-175` |
| `load_general_plugins()`（引擎/调度器进程也加载插件） | `core.py:106-109` |
| `_initialize_kv_caches` | `core.py:132,236` |
| Scheduler 创建 | `core.py:136-157` |
| KV connector handshake metadata 收集 | `core.py:167-175` |
| `EngineCoreProc.run_busy_loop` | `core.py:1223` |
| `AscendMultiprocExecutor._init_executor`（插件继承） | `vllm_plugins/.../its_multiproc_executor.py:254-323` |
| ITS HTTP server 启动 | `its_multiproc_executor.py:312-317` |
| `_init_workers` | `its_multiproc_executor.py:1586-1802` |
| Worker 进程入口 | `origin_0.23.0/vllm/vllm/v1/executor/multiproc_executor.py:807-879` |
| Worker 初始化/模型加载 | `multiproc_executor.py:594-652` |
| NPU worker `init_device` / `load_model` | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/worker.py:529,705` |
| worker 分布式环境初始化 | `vllm_plugins/.../zero_interrupt/vllm_ascend/worker/worker.py:1025-1155` |

## 2. 进程与线程（vLLM v1 多进程结构）

以 P 节点一个 dp_rank 进程为例（`launch_prefill_hetero_test.sh` 共启动 4 个）：

```text
python -m vllm.entrypoints.openai.api_server (dp_rank=N)
├─ API server / AsyncLLM 前端（uvicorn）
├─ [仅 dp_rank=0] DP Coordinator 进程
├─ EngineCoreProc 进程（1 个，由 MPClient 启动）
│   ├─ ITSMultiprocExecutor
│   │   ├─ ITSHttpServer 线程
│   │   ├─ StrategySyncThread
│   │   ├─ ITSHealthMonitor 线程
│   │   └─ ITSNPUWorker 子进程 × TP_SIZE（P 初始 4，D 为 1）
│   └─ Scheduler + KVCacheManager
```

D 节点同理，每个 `dp_rank` 进程 1 个 EngineCoreProc，TP1 时 1 个 worker。
因此静态总进程数：

- P：4 前端 + 1 DP Coordinator + 4 EngineCore + 16 worker；
- D：16 前端 + 1 DP Coordinator + 16 EngineCore + 16 worker。

## 3. HTTP 请求

| 阶段 | 端点/消息 | 说明 |
|---|---|---|
| EngineCore 启动握手 | ZMQ `HELLO/READY`，非 HTTP | `utils.py:1202-1299` |
| worker 就绪握手 | ready pipe `READY`，非 HTTP | `multiproc_executor.py:862-869` |
| 服务就绪 | `GET /health` | launch 脚本用 `check_http` 探测 |
| ITS 就绪 | `GET /health`（ITS 端口） | executor 内嵌 FastAPI |
| DC 注册（DC 场景） | `POST /api/v1/decision_center/init_executor_state` | executor `_report_init_state` |

## 4. 环境变量

见 `01_install_launch.md`。启动链额外消费：

- `--data-parallel-size/rank/address/rpc-port` 决定 DPLB/内部 LB 与 EngineCore 数量；
- `VLLM_WORKER_MULTIPROC_METHOD` 可选 forkserver（脚本未设置）；
- `VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=30000` 影响 `collective_rpc` 超时；
- `VLLM_ITS_HTTP_SERVER_PORT_START` 决定 ITS HTTP 端口。

## 5. 函数调用链

### 5.1 前端进程

```text
python3 -m vllm.entrypoints.openai.api_server
  → run_server
    → run_server_worker
      → build_async_engine_client
          AsyncEngineArgs.from_cli_args
          engine_args.create_engine_config
      → build_async_engine_client_from_engine_args
          AsyncLLM.from_vllm_config
            AsyncLLM.__init__
              InputProcessor / OutputProcessor
              EngineCoreClient.make_async_mp_client
                data_parallel_size>1 → DPLBAsyncMPClient
                  MPClient.__init__
                    ZMQ input/output sockets
                    launch_core_engines
                      dp_rank=0 → DPCoordinator 进程
                      CoreEngineProcManager → EngineCoreProc 进程
                    wait_for_engine_startup
```

### 5.2 EngineCoreProc 进程

```text
EngineCoreProc（EngineCore.__init__）
  → load_general_plugins()        ← 插件在此进程再次加载
      register_patches → apply_from_env → deepseekv4 patch 全部生效
  → model_executor = ITSMultiprocExecutor(vllm_config)
      ITSMultiprocExecutor.__init__
        super().__init__（AscendMultiprocExecutor）
      ITSMultiprocExecutor._init_executor
        super()._init_executor()（AscendMultiprocExecutor._init_executor）
          MessageQueue（scheduler output 广播）
          AscendWorkerProc.make_worker_process × world_size
        DecisionCenterClient / StrategySyncThread
        ITSHttpServer.start()
        _report_init_state
      ITSMultiprocExecutor._init_workers / super()._init_executor 内
        worker 子进程启动
  → _initialize_kv_caches
      get_kv_cache_specs → determine_available_memory → get_kv_cache_configs
  → Scheduler + KVCacheManager
  → 收集 worker KV connector handshake metadata
  → run_busy_loop（插件 patch 后进入 ITS 策略消费逻辑）
```

### 5.3 Worker 子进程

```text
AscendWorkerProc.make_worker_process
  → WorkerProc.worker_main
      WorkerProc.__init__（插件替换为 ITSNPUWorker）
        WorkerWrapperBase.init_worker
          NPUWorker.__init__
            init_device（NPU 设备）
            _init_worker_distributed_environment
              对称启动：init_distributed_environment → init_ascend_model_parallel
        worker.load_model()
          ModelConfig.verify_with_parallel_config（已 patch）
          model_loader（已 patch 的 hetero default loader）
          DeepSeek-V4 模型实例化：
            Linear/DSA/MoE 等 17 个 hetero patch 已就位
        ready pipe 发送 READY
      worker.worker_busy_loop（等待 scheduler_output）
```

### 5.4 启动期插件 patch 挂载点

见 `01_install_launch.md` 第 5 节：入口分流、`deepseekv4/patch.py` 顺序、
17 个 hetero patch 和 8 个整文件替换目标。

## 6. 在 8 条路径中的差异

| 路径 | 差异 |
|---|---|
| P1/P2/P3/P4 | 各自在编排脚本里检查健康，按需拉起 P；D 假定已拉起 |
| P5/P6 | 服务必须已在运行，本阶段不执行 |
| P7 | 检查/按需拉起 D |
| P8 | 复用 P7 后的 D |

## 7. 不确定点

- `DPLBAsyncMPClient` 与 `DPAsyncMPClient` 分支由 parallel_config 派生，
  脚本 CLI 未显式 `--data-parallel-external-lb`，静态判断为内部 LB；
- 每个前端进程管理的 EngineCore 数量由 `data_parallel_size_local` 决定，本文按脚本
  单节点 DP 布局推导为 1；
- `load_general_plugins()` 在 EngineCore 进程再次执行，确保插件 patch 在调度器/worker
  两侧生效；若插件加载失败，启动行为取决于 patch 的 fail-fast 策略；
- vLLM 内部版本细节以 origin_0.23.0 为准，安装时已被 setup.py 替换的文件以
  `vllm_plugins/.../zero_interrupt/` 主目录为准。
