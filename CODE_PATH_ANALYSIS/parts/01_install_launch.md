# 阶段 01：安装与拉起

覆盖 `install_vllm_plugins.sh`、`launch_prefill_hetero_test.sh`、`pd_hetero/decode/launch_decode_pd.sh`
以及每个 vllm serve 进程启动后的插件 patch 应用链。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| 构建并安装 wheel | `vllm_plugins_hetero_test/install_vllm_plugins.sh:77-90` |
| setup.py 整文件替换 | `vllm_plugins/setup.py:111-203` |
| P launch 环境变量 | `launch_prefill_hetero_test.sh:61-110` |
| P 启动 4 个 engine | `launch_prefill_hetero_test.sh:112-177` |
| P 健康等待 | `launch_prefill_hetero_test.sh:198-225` |
| D launch 环境变量 | `pd_hetero/decode/launch_decode_pd.sh:69-111` |
| D 启动 16 个 engine | `pd_hetero/decode/launch_decode_pd.sh:113-182` |
| D 健康等待 | `pd_hetero/decode/launch_decode_pd.sh:201-224` |
| 插件入口 | `vllm_plugins/vllm_custom_plugins/__init__.py:95-122` |
| patch 族分流 | `vllm_plugins/vllm_custom_plugins/plugins/zero_interrupt/patch.py:20-38` |
| deepseekv4 patch 清单 | `.../deepseekv4/patch.py:18-414` |
| ITS executor/worker 初始化 | `.../deepseekv4/vllm/v1/executor/its_multiproc_executor.py:110-174,254-323,2655-2686` |
| worker 分布式初始化 | `.../zero_interrupt/vllm_ascend/worker/worker.py:1025-1155` |

## 2. 进程与线程

### 2.1 进程布局（静态定义）

| 节点 | 进程 | 数量 | 说明 |
|---|---|---|---|
| P 节点 | `python3 -m vllm.entrypoints.openai.api_server` | 4 | DP0..3，端口 9000..9003 |
| P 节点 | 每个 engine 内的 ITS executor | 4 | 同一进程内组件，非独立进程 |
| P 节点 | 每个 executor 的 worker 进程 | 4×4=16 | 初始对称 `DP4TP4` |
| P 节点 | ITS HTTP server | 每 executor 1 个线程 | 端口 8001/8005/8009/8013 |
| P 节点 | 健康监控线程 | 每 executor 1 个 | `ITSHealthMonitor` |
| D 节点 | `python3 -m vllm.entrypoints.openai.api_server` | 16 | DP0..15，端口 9100..9115 |
| D 节点 | 每个 executor 的 worker 进程 | 16×1=16 | `DP16TP1` |
| D 节点 | ITS HTTP server | 每 executor 1 个线程 | 端口 18001..18016 |

要点：executor 与 EngineCore 在同一个 `vllm serve` 进程内；worker 是 executor 派生的独立进程。

### 2.2 启动期线程/组件初始化顺序

```text
vllm serve 进程
  ├─ 插件入口线程（主进程启动阶段）
  ├─ EngineCore busy loop
  ├─ ITSHttpServer daemon 线程          its_multiproc_executor.py:312-317
  │    └─ uvicorn 线程                  http_server.py:284-321
  ├─ StrategySyncThread                 its_multiproc_executor.py:267-271
  └─ ITSHealthMonitor 线程              its_multiproc_executor.py:325-334
```

## 3. HTTP 请求

本阶段主要 HTTP：

| 端点 | 发起方 | 用途 |
|---|---|---|
| `GET 127.0.0.1:9000+dp/health` | launch 脚本 | P engine 就绪检查 |
| `GET 127.0.0.1:9100+dp/health` | launch 脚本 | D engine 就绪检查 |
| `POST <DC>/api/v1/decision_center/init_executor_state` | executor | DC 注册（DC URL 有效时） |

DC 注册由 `_report_init_state` 发起（`its_multiproc_executor.py:323,478-489`），
DC 返回的 `exe-...` executor id 被加入 ITS HTTP server 的 `accepted_executor_ids`。

## 4. 环境变量

| 变量 | P 默认 | D 默认 | 作用 |
|---|---|---|---|
| `VLLM_ITS_DEEPSEEK_V4` | 1 | 1 | DeepSeek-V4 patch 族 |
| `VLLM_CUSTOM_PATCHES` | `zero_interrupt` | `zero_interrupt` | 应用 zero_interrupt 插件 |
| `VLLM_CUSTOM_PLUGINS_SKIP_LICENSE` | 1 | 1 | 跳过 license 校验 |
| `VLLM_ITS_ENABLE_FAULT_KEEP` | true | true | 故障保持 |
| `VLLM_ITS_ENABLE_PD_REBUILD` | true | true | PD_REBUILD 能力 |
| `VLLM_ITS_HTTP_SERVER_PORT_START` | 8001 | 18001 | ITS HTTP 端口基址 |
| `VLLM_ITS_DECISION_CENTER_URL` | `127.0.0.1:1` | `127.0.0.1:1` | 非 DC 场景指向不可达；DC launch wrapper 覆盖 |
| `VLLM_ITS_STRATEGY_TIMEOUT` | 600 | 600 | 策略超时 |
| `VLLM_ITS_MAX_RETRY_COUNT` | 1 | 1 | 重启重试次数 |
| `VLLM_SERVICE_ID` | `hetero-test-dp4tp4-dp<rank>` | `pd-hetero-decode-dp<rank>` | DC 注册服务号；DC wrapper 统一为 `pd-hetero-service` |
| `ASCEND_RT_VISIBLE_DEVICES` | P：每组 4 卡 | D：单卡 | 可见 NPU |

## 5. 函数调用链

```text
install_vllm_plugins.sh
  → python3 -m pip wheel --no-build-isolation .
  → setup.py 替换 8 个整文件（rotary、ascend parallel_state、ascend worker、
    patch_qwen3_5、fused_moe/config、parallel、vllm parallel_state、kv_cache_utils）
  → pip install --force-reinstall wheel

launch_prefill_hetero_test.sh
  → launch_engine ×4
      python3 -m vllm.entrypoints.openai.api_server
        → vllm general_plugins entry point
          → register_patches()
            → PLUGINS 注册
            → apply_from_env()
              → zero_interrupt/patch.py.apply()
                → is_deepseek_v4_enabled() == true
                → deepseekv4/patch.py.apply()
                    ├─ tool parser 注册
                    ├─ engine_core_patch.patch_engine_core()
                    ├─ core_client_patch.patch_dplb_client()
                    ├─ MultiprocExecutor→ITSMultiprocExecutor
                    ├─ WorkerProc→ITSNPUWorker
                    ├─ NPUWorker.update_kv_connector_for_pd
                    ├─ ModelConfig.verify_with_parallel_config
                    ├─ kv_cache_utils.get_kv_cache_configs
                    └─ 17 个 hetero patch（linear/DSA/MoE/forward/Mooncake 等）
        → ITSMultiprocExecutor._init_executor()
            DecisionCenterClient → StrategySyncThread → ITSHttpServer → _report_init_state
        → _init_workers()
            ITSNPUWorker.__init__
              → StrategyHandler 挂载
              → _init_worker_distributed_environment
                  P 对称：普通 init_ascend_model_parallel
                  D TP1：普通 init_ascend_model_parallel
              → 模型加载 / KV cache 初始化
```

`deepseekv4/patch.py:296-414` 的 17 个 hetero patch 清单：

| # | 模块（`deepseekv4/` 前缀） | apply 函数 | patch.py 行号 |
|---|---|---|---|
| 1 | `vllm.distributed.patch_hetero_utils` | `apply_hetero_distributed_utils_patch` | 296-302 |
| 2 | `vllm.model_executor.layers.patch_hetero_parameter` | `apply_hetero_parameter_patch` | 303-309 |
| 3 | `vllm.model_executor.layers.patch_hetero_vocab` | `apply_hetero_vocab_patch` | 310-316 |
| 4 | `vllm.model_executor.layers.fused_moe.runner.patch_hetero_moe_runner` | `apply_hetero_moe_runner_patch` | 317-323 |
| 5 | `vllm.model_executor.model_loader.patch_hetero_default_loader` | `apply_hetero_default_loader_patch` | 324-330 |
| 6 | `vllm.config.patch_speculative_hetero` | `apply_speculative_hetero_patch` | 331-337 |
| 7 | `vllm_ascend.models.patch_deepseek_v4` | `apply_deepseek_v4_hetero_patch` | 338-344 |
| 8 | `vllm_ascend.models.patch_deepseek_v4_mtp` | `apply_deepseek_v4_mtp_hetero_patch` | 345-351 |
| 9 | `vllm_ascend.patch.patch_hetero_tp` | `apply_hetero_forward_context_patch` | 352-358 |
| 10 | `vllm_ascend.patch.patch_hetero_ascend_config` | `apply_hetero_ascend_config_patch` | 359-365 |
| 11 | `vllm_ascend.ops.patch_hetero_custom_ops` | `apply_hetero_custom_ops_patch` | 366-372 |
| 12 | `vllm_ascend.ops.patch_hetero_ascend_linear` | `apply_hetero_ascend_linear_patch` | 373-379 |
| 13 | `vllm_ascend.ops.fused_moe.patch_hetero_moe` | `apply_hetero_moe_patch` | 380-386 |
| 14 | `vllm_ascend.attention.patch_deepseek_v4_attention_hetero` | `apply_deepseek_v4_attention_hetero_patch` | 387-393 |
| 15 | `vllm_ascend.worker.patch_hetero_model_runner` | `apply_hetero_model_runner_patch` | 394-400 |
| 16 | `vllm_ascend.spec_decode.patch_hetero_spec_decode` | `apply_hetero_spec_decode_patch` | 401-407 |
| 17 | `vllm_ascend.distributed.kv_transfer.patch_hetero_mooncake` | `apply_hetero_mooncake_patch` | 408-414 |

setup.py 统一整文件替换目标（`vllm_plugins/setup.py:111-203`）：

| 替换源（主目录 `zero_interrupt/` 下） | 安装目标 |
|---|---|
| `vllm/config/parallel.py` | `<vllm>/config/parallel.py` |
| `vllm/distributed/parallel_state.py` | `<vllm>/distributed/parallel_state.py` |
| `vllm/model_executor/layers/fused_moe/config.py` | `<vllm>/model_executor/layers/fused_moe/config.py` |
| `vllm/v1/core/patch_kv_cache_utils.py` | `<vllm>/v1/core/kv_cache_utils.py` |
| `vllm_ascend/distributed/parallel_state.py` | `<vllm_ascend>/distributed/parallel_state.py` |
| `vllm_ascend/worker/worker.py` | `<vllm_ascend>/worker/worker.py` |
| `vllm_ascend/patch/worker/patch_qwen3_5.py` | `<vllm_ascend>/patch/worker/patch_qwen3_5.py` |
| `vllm_ascend/ops/triton/rotary_embedding.py` | `<vllm_ascend>/ops/rotary_embedding.py` |

## 6. 本阶段在 8 条路径中的差异

| 路径 | P 拉起 | D 拉起 |
|---|---|---|
| P1/P2 | `run_scenario1.sh` 检查后按需拉起 | 假定 D 已由外部 `launch_decode_pd.sh` 拉起 |
| P3/P4 | `run_scenario2.sh` 检查后按需拉起 | 同上 |
| P5/P6 | 复用已运行服务，不拉起 | 复用已运行服务，不拉起 |
| P7 | 无 P | `run_decode_fault_alone.sh` 检查后按需拉起 D |
| P8 | 无 P | 复用 P7 后的 D，不重新拉起 |

## 7. 不确定点

- 若服务已被外部预先拉起，launch 脚本不执行，实际 patch 族/安装版本取决于既有进程环境；
  测试脚本不校验 `applying DeepSeek-V4 patch family`。
- `PYTHON_BIN`、`MODEL_PATH`、DP/TP/端口等默认值均可被外部环境覆盖；
- 安装脚本构建的是 `${VLLM_PLUGINS_REPO}` 当前工作区，未校验 git commit；
- P/D launch 默认非 DC 的 `VLLM_SERVICE_ID` 不同，直接用 DC 测试必须由
  `decision_center/launch_*_dc.sh` 统一 `VLLM_SERVICE_ID`。
