# 阶段 05：重启 / 恢复执行

覆盖 executor 收到策略后的公共链，以及 P 异构重启、D 缩容、P RECOVER、D RECOVER 四条执行路径。

## 1. 公共链：策略接收 → 消费 → 执行

### 1.1 代码行号

| 步骤 | 文件:行号 |
|---|---|
| deploy 路由 | `deepseekv4/vllm/v1/executor/http_server.py:129-189` |
| 策略解析 | `http_server.py:191-282` |
| 回调 | `strategy_sync.py:51-79` |
| 置事件/暂停/WAKEUP | `its_multiproc_executor.py:672-702` |
| busy loop 消费 | `deepseekv4/vllm/v1/engine/engine_core_patch.py:255-401` |
| 执行部署 | `engine_core_patch.py:729-894` |
| deploy_type 分派 | `its_multiproc_executor.py:713-745` |
| DEGRADE | `its_multiproc_executor.py:1880-1910` |
| RECOVER | `its_multiproc_executor.py:1913-1961` |
| PD_REBUILD | `its_multiproc_executor.py:1964-2040` |
| 全量重启 | `its_multiproc_executor.py:1181-1245` |
| barrier | `its_multiproc_executor.py:944-1179` |
| 配置注入 | `its_multiproc_executor.py:1804-1862` |
| 新配置应用 | `its_multiproc_executor.py:2312-2570` |
| worker 初始化 | `its_multiproc_executor.py:1586-1802` |
| KV cache 重建 | `its_multiproc_executor.py:1263-1337,1339-1403` |
| barrier 工具 | `deepseekv4/vllm/v1/executor/utils.py:8-349` |

### 1.2 进程与线程

- **executor/EngineCore 所在 vllm serve 进程不重启**；
- 变化的是 executor 管理的 **worker 进程**：
  - P 异构：16→15；
  - D 缩容：16→15（rank15 无 worker）；
  - P RECOVER：15→16；
  - D RECOVER：15→16（rank15 从 0→1）。
- ITS HTTP server、StrategySyncThread、健康监控线程保持/按需重启；
- 缩零 executor 的健康监控被停止。

### 1.3 HTTP 请求

本阶段没有测试脚本发起的 HTTP；执行链由阶段 04 已送达的策略驱动。

### 1.4 环境变量

策略执行主要读取已注入的 `vllm_config.additional_config["zero_interrupt_config"]`；
进程级仍受 `VLLM_ITS_ENABLE_PD_REBUILD`、`VLLM_ITS_STRATEGY_TIMEOUT`、
`VLLM_ITS_MAX_RETRY_COUNT`、`VLLM_ITS_HEALTH_CHECK_INTERVAL` 影响。

### 1.5 函数调用链（公共）

```text
ITSHttpServer.deploy
  → _parse_deploy_request
  → executor_id 校验
  → StrategySyncThread.on_strategy_received
      → executor._on_strategy_sync → _on_deploy_strategy_received
          current_strategy 保存
          recv_new_deployment.set()
          _engine_core_ref._paused_for_restart = True
          trigger_busy_loop()
            → input_queue.put_nowait((WAKEUP, None))
  → EngineCoreProc._handle_shutdown(patched)
      abort 未完成请求
      → _execute_deployment_strategy(engine_core, executor)
          ├─ PD 分离时 engine_id / scheduler connector 更新
          ├─ executor.handle_new_deployment()
          │    → execute_deploy_strategy()
          │        DEGRADE → _execute_degrade_strategy
          │        RECOVER → _execute_recover_strategy
          │        PD_REBUILD → _execute_pd_rebuild_strategy
          ├─ update_kv_connector_metadata
          └─ 设置 zero_interrupt_mode / idle / recovered 通知
```

### 1.6 不确定点

- `step` 与 `step_with_batch_queue` 两个 patch 实际命中哪一个由 vLLM 内部
  `batch_queue`/`max_concurrent_batches` 决定（P 未开 async-scheduling，D 开了）。
- 真实 NPU 故障路径（health monitor 触发 `wait_new_deployment`）不经过本 8 条脚本路径。

## 2. P 异构重启（P1/P2 命中，DP4TP4→DP4TP(3,4,4,4)）

### 2.1 代码行号

- P1 入口：`its_multiproc_executor.py:736-737→1964-2040`；
- P2 入口：`its_multiproc_executor.py:732-733→1880-1910`；
- full_restart 判定：`its_multiproc_executor.py:2094-2182`；
- 异构配置注入：`its_multiproc_executor.py:1831-1859`；
- sharding fallback `[2,1,1]`：`v1/executor/utils.py:59-103`；
- P 数据面：linear/DSA/MoE/forward/Mooncake patch（见阶段 01 与旧总矩阵）。

### 2.2 进程与线程

- P 4 个 vllm serve 进程存活；
- 旧 16 个 P worker 全部退出；
- 新 worker：DP0 起 3 个，DP1-3 各起 4 个，共 15 个；
- D 全部进程/线程不变。

### 2.3 函数调用链

```text
P1: _execute_pd_rebuild_strategy
      full_restart=true（new_tp 变化 + shardings）
      → _cleanup_and_restart_workers
P2: _execute_degrade_strategy
      → _cleanup_and_restart_workers
          ├─ _barrier_for_full_restart
          │    无缩零、当前 dp=4 且目标 dp=4 → 沿用现有 4-rank dp_group
          │    all_reduce → "Full-restart barrier passed"
          ├─ _cleanup_scheduler_requests
          ├─ _cleanup_message_queues_and_workers（旧 worker 退出）
          ├─ _update_vllm_config_for_restart
          │    注入 heterogeneous_dp_config=[3,4,4,4]
          │    global_world_size=15，global_start_rank=0/3/7/11
          ├─ _init_workers
          │    DP0：3 个 ITSNPUWorker
          │    DP1-3：各 4 个 ITSNPUWorker
          │    worker 分布式初始化走 init_ascend_model_parallel_asym
          ├─ health monitor 重启
          └─ _reinitialize_kv_cache
               get_kv_cache_configs
               _rebuild_scheduler_kv_cache_manager
  → _execute_deployment_strategy 收尾
      P 为 kv_producer 且 full_restart → engine_id 轮换
      update_kv_connector_metadata
```

### 2.4 环境变量

同阶段 01；本阶段新增读取 `zero_interrupt_config`（内含 executor_id、heterogeneous_dp_config、
tp_asymmetric_shardings、global_world_size、global_start_rank）。

### 2.5 不确定点

- P2 的 DEGRADE payload 不含 shardings，依赖 fallback 推导 `[2,1,1]`；
- P1 若外部覆盖 `DEPLOY_TYPE`/`SIMULATE_FAULT`，分支可能偏离默认路径。

## 3. D 缩容（P3/P4/P7 命中，DP16TP1→DP15TP1）

### 3.1 代码行号

- 健康 executor：`its_multiproc_executor.py:1964-2040`（P3/P7）或 `:1880-1910`（P4）；
- 缩零识别：`utils.py:228-246`；
- barrier geometry：`utils.py:280-349`；
- 15-rank 组重建：`its_multiproc_executor.py:1066-1070,1167-1174`；
- rank15 skipped：`its_multiproc_executor.py:988-1001`；
- rank15 Idle：`its_multiproc_executor.py:1701-1718` 与 `:1222-1226`。

### 3.2 进程与线程

- D 16 个 vllm serve 进程存活；
- rank0..14 的旧 worker 退出，各重建 1 个 worker；
- rank15 worker 清空，world_size=0，进入 Idle；
- P 全部进程/线程不变；
- P4 的 rank15 还会收到 idle 带内通知（`engine_core_patch.py:886-890`），P3 不触发该通知。

### 3.3 函数调用链

```text
健康 executor（0..14）：
  _execute_pd_rebuild_strategy / _execute_degrade_strategy
    → full_restart=true（存在 new_dp=0/new_tp=0）
    → _cleanup_and_restart_workers
        ├─ get_surviving_dp_barrier_geometry
        │    scale_to_zero={15}，幸存者 15 个并重编号 0..14
        ├─ _build_surviving_dp_group(15-rank gloo)
        ├─ barrier passed
        ├─ _adopt_surviving_dp_group（dp_group 16→15）
        ├─ _get_engine_parallel_config 纯 DP 缩容分支
        ├─ _init_workers（每 executor 1 worker）
        └─ KV cache 重建

故障 executor（15）：
  _barrier_for_full_restart
    surviving_dp_size=0 → skipped
    _mark_scale_to_zero_dp_excluded
  _cleanup_and_restart_workers
    → _init_workers：new_dp=0/new_tp=0 → world_size=0
    → "Idle mode (dp=0)"
```

### 3.4 环境变量

同阶段 01 + `zero_interrupt_config`；触发侧使用 `DECODE_FAULT_NPU=15`。

### 3.5 不确定点

- 若 rank15 在 P3/P7 手动路径不可达，它可能未执行缩零策略，而健康侧仍按 15-rank barrier 完成；
- P3 与 P4 的 deploy_type 不同，导致 idle 通知和 `zero_interrupt_mode` 设置不同。

## 4. P RECOVER（P5/P6 命中，DP4TP(3,4,4,4)→DP4TP4）

### 4.1 代码行号

- 入口：`its_multiproc_executor.py:1913-1961`；
- full_restart 判定（当前异构）：`its_multiproc_executor.py:2105-2137`；
- RECOVER 备份断言：`its_multiproc_executor.py:2428-2439`；
- barrier 沿用 4-rank：`its_multiproc_executor.py:1019-1022`；
- P engine_id 再次轮换：`engine_core_patch.py:768-777`。

### 4.2 进程与线程

- P 4 个 serve 进程存活；
- 旧 15 个 P worker 退出；
- 新 16 个 P worker（4/4/4/4）重建；
- D 在 P 恢复阶段不变，恢复后仍 15 个 worker。

### 4.3 函数调用链

```text
_execute_recover_strategy
  → 首次恢复不命中幂等跳过
  → _cleanup_and_restart_workers
      ├─ current_is_heterogeneous=true → full_restart=true
      ├─ barrier：无缩零、目标 dp=当前 dp=4 → 沿用现有 4-rank group
      ├─ _get_engine_parallel_config RECOVER 分支
      │    断言 backup dp/tp/rank；heterogeneous_dp_config 置 None
      ├─ _init_workers：恢复对称 4/4/4/4
      └─ KV cache 重建
  → P 是 producer 且 full_restart → engine_id 再次轮换
  → update_kv_connector_metadata
```

### 4.4 环境变量

`DEPLOY_TYPE=RECOVER`、`zero_interrupt_config`；其余同阶段 01。

### 4.5 不确定点

- 如果 P 当前状态与备份对称配置不一致（例如从未 DEGRADE），RECOVER 分支的断言会失败；
- 幂等分支要求 `data_parallel_size > 1`，当前 P=4 满足。

## 5. D RECOVER（P5/P6/P8 命中，DP15TP1→DP16TP1）

### 5.1 代码行号

- 入口：`its_multiproc_executor.py:1913-1961`；
- 纯 DP 恢复 full_restart：`utils.py:249-277`；
- 16-rank 目标组重建：`its_multiproc_executor.py:1035-1067`；
- 16 个全部 passed：`its_multiproc_executor.py:1175`；
- rank15 恢复 worker：`its_multiproc_executor.py:1586-1802`。

### 5.2 进程与线程

- D 16 个 serve 进程存活；
- 旧 15 个 worker 退出；
- 新 16 个 worker（每 executor 1 个）重建，恢复的 rank15 参与 barrier；
- P 在 P5/P6 已完成自身恢复，16 个 P worker。

### 5.3 函数调用链

```text
_execute_recover_strategy（每个 D executor）
  → 健康 0..14：backup dp=16 vs current dp=15 → full_restart=true
  → rank15：backup dp=16 vs current dp=0 → full_restart=true
  → _cleanup_and_restart_workers
      ├─ barrier：无缩零、目标 16 ≠ 当前 15/被排除
      │    _build_surviving_dp_group(16-rank)
      │    16 个 executor 全部 barrier passed
      ├─ _adopt_surviving_dp_group（dp_group 15→16）
      ├─ _get_engine_parallel_config RECOVER 分支
      ├─ _init_workers：rank15 重新起 1 个 worker
      └─ KV cache 重建
```

### 5.4 环境变量

`DEPLOY_TYPE=RECOVER`；`DECODE_DP_SIZE=16`、`DECODE_FAULT_NPU=15` 决定恢复目标。

### 5.5 不确定点

- rank15 若未执行过 DEGRADE/PD_REBUILD（无 backup），RECOVER 分支退化为按当前配置恢复，
  但 `recover_requires_full_restart` 仍会因目标 dp≠当前 dp 判 true；
- 恢复后的 executor15 必须 `Full-restart barrier passed` 而非 skipped，脚本通过
  `trigger_decode_recover.sh` 的 16 个日志 marker 等待间接校验。

## 6. 统一整文件替换在本阶段的分支速查

| 文件（`zero_interrupt/` 主目录） | P 异构重启 | D 缩容 | P RECOVER | D RECOVER |
|---|---|---|---|---|
| `vllm/config/parallel.py` | H：`heterogeneous_dp_config=[3,4,4,4]`、offset 0/3/7/11 | S：纯 DP | S：恢复对称，hetero config 置 None | S |
| `vllm/distributed/parallel_state.py` | H：`get_rank_offset_for_dp` | S | S | S |
| `vllm/model_executor/layers/fused_moe/config.py` | H：`flatten_tp_across_dp_and_pcp` 异构分支 | S | S | S |
| `vllm/v1/core/patch_kv_cache_utils.py` | D4：DeepSeek-V4 KV 分支 | D4 | D4 | D4 |
| `vllm_ascend/distributed/parallel_state.py` | A：`init_ascend_model_parallel_asym` | S | A（对称目标） | S |
| `vllm_ascend/worker/worker.py` | A：DeepSeek hetero 分支 | S | A（对称目标） | S |
| `vllm_ascend/patch/worker/patch_qwen3_5.py` | N：Qwen 类不实例化 | N | N | N |
| `vllm_ascend/ops/triton/rotary_embedding.py` | 原生（`its_rotary` 未启用） | 原生 | 原生 | 原生 |

图例：H=异构分支；A=asym/重启分支；S=对称普通分支；D4=DeepSeek-V4 KV 分支；N=不命中。
