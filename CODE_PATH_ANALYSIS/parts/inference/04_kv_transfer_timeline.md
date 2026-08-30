# 推理细节 04：Mooncake KV 传输时序

聚焦 P 端发布元数据、D 端首次/后续请求拉取 KV 的时序，以及异构 P 重启后的新
`(engine_id, handshake_port)` 恢复链。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| 基类 metadata 结构 | `origin_0.23.0/vllm-ascend/vllm_ascend/distributed/kv_transfer/kv_p2p/mooncake_hybrid_connector.py:82-92` |
| 基类 KVCacheRecvingThread | `mooncake_hybrid_connector.py:365-...` |
| 基类 recv run / 提交 / 传输 | `mooncake_hybrid_connector.py:511-525,538-578,641-...` |
| 基类 `_get_remote_metadata` | `mooncake_hybrid_connector.py:956-979` |
| 基类 Worker init | `mooncake_hybrid_connector.py:1480-...` |
| 基类 Worker register_kv_caches | `mooncake_hybrid_connector.py:1604-...` |
| 基类 Worker start_load_kv | `mooncake_hybrid_connector.py:1770-...` |
| 基类 remote host 查询 | `mooncake_hybrid_connector.py:1865-1878` |
| patch 扩展 metadata | `vllm_plugins/.../deepseekv4/vllm_ascend/distributed/kv_transfer/patch_hetero_mooncake.py:41-61` |
| patch 端口 offset | `patch_hetero_mooncake.py:63-81` |
| patch scheduler init | `patch_hetero_mooncake.py:84-181` |
| patch worker init | `patch_hetero_mooncake.py:226-...` |
| patch register_kv_caches | `patch_hetero_mooncake.py:804-...` |
| patch start_load_kv | `patch_hetero_mooncake.py:455-565` |
| patch remote host 查询 | `patch_hetero_mooncake.py:399-441` |
| patch `_get_remote_metadata` | `patch_hetero_mooncake.py:630-670` |
| patch `_transfer_kv_cache_all_groups` | `patch_hetero_mooncake.py:673-801` |

## 2. 进程与线程

| 组件 | 位置 | 说明 |
|---|---|---|
| `MooncakeConnectorScheduler` | D EngineCoreProc | 调度器侧状态/block ids |
| `MooncakeConnectorWorker` | D ITSNPUWorker 进程 | 实际传输/缓存 |
| `KVCacheRecvingThread` | D ITSNPUWorker 进程内线程 | 异步拉取远程 KV |
| `KVCacheSendingThread` | P ITSNPUWorker 进程内线程 | P 端发送 |
| `KVCacheTaskTracker` | 双方 | 跟踪任务完成 |

## 3. HTTP 请求

传输控制使用 ZMQ side-channel，不走 HTTP：
- 握手 socket：`tcp://<host>:<handshake_port>`；
- 传输端口由 `kv_port + 累计 offset + device_index` 派生。

## 4. 环境变量

`kv_transfer_config.kv_role/kv_port/engine_id`、
`ASCEND_CONNECT_TIMEOUT`、`ASCEND_TRANSFER_TIMEOUT`、`MC_TRANSFER_TIMEOUT`。

## 5. 时序

### 5.1 P 端发布元数据（启动/重启后）

```text
P worker 启动 → MooncakeConnectorWorker.__init__（patch）
  计算 side_channel_port：
    异构：kv_port + get_rank_offset_for_dp(dp_rank)
    对称：kv_port + dp_rank*tp_size*pp*pcp
  handshake_port = side_channel_port + device_index
KV cache 注册：
  register_kv_caches（patch）
    → MooncakeAgentMetadata{
        host, port(handshake_port),
        engine_id, tp_rank, pp_rank, dp_rank,
        block_strides...
      }
    → 写入 xfer_handshake_metadata
scheduler 收集 metadata：
  EngineCore._initialize_kv_caches 之后 get_kv_connector_handshake_metadata
  → MooncakeConnectorScheduler.set_xfer_handshake_metadata
  → 对外发布 multi_nodes_meta_mapping[key]={engine_id, handshake_port, ...}
```

### 5.2 D 端首次请求

```text
D scheduler 分配块，connector.update_state_after_alloc 记录 kv_transfer_params
D worker 收到 scheduler_output：
  start_load_kv（patch）
    → 解析 remote_engine_id / remote_host / remote_handshake_port
    → 查缓存 kv_caches_base_addr[engine_id][remote_handshake_port]
    未命中：
      KVCacheRecvingThread._get_remote_metadata（patch）
        → ZMQ 连 remote_host:remote_handshake_port
        → 接收 MooncakeAgentMetadata
        → 以 (engine_id, handshake_port) 为键缓存：
            kv_caches_base_addr / remote_te_port /
            remote_block_lens / remote_block_strides
      _submit_request → transfer task
    → _transfer_kv_cache_all_groups（patch）
      → 从 P 的 remote_block_ids 拉取各 KV group
    → KVCacheTaskTracker 记录任务完成
D scheduler 下轮：
  finished_recving 集合更新
  → WAITING_FOR_REMOTE_KVS → WAITING
  → 正常 decode 前向
```

### 5.3 D 端后续请求

- 若 `(engine_id, handshake_port)` 已缓存，直接走 `_transfer_kv_cache_all_groups`；
- 若未缓存（如 P 重启后 engine_id 变化），回到 5.2 的握手路径。

### 5.4 异构 P 重启后的恢复

```text
P full_restart：
  engine_core_patch._execute_deployment_strategy
    kv_producer + full_restart → engine_id = <orig>-<uuid>
    scheduler/worker connector engine_id 同步
    side_channel_port 按异构 offset 更新
P 新 worker 注册新 metadata：
  (new_engine_id, new_handshake_port) → multi_nodes_meta_mapping
D 后续请求：
  kv_transfer_params 携带新 remote_engine_id/remote_port
  缓存旧 key 不命中 → patch _get_remote_metadata 重新握手
  → 新 key 写入缓存 → KV 传输恢复
```

## 6. 线程等待关系（静态判断）

- P 侧 `KVCacheSendingThread` 是单线程 ZMQ ROUTER 忙等，`ready_event` 在 bind 成功后置位；
- D 侧 `KVCacheRecvingThread` 是单线程调度器：`run()` 立即 ready 并阻塞在
  `request_queue.get()`；真正传输在 `ThreadPoolExecutor(max_workers=32)` 的 worker 线程执行
  （`mooncake_hybrid_connector.py:412-423,511-523,538-569`）；
- `start_load_kv` 只入队，模型前向不等待 recv 线程；`wait_for_save` 对 Mooncake 是 no-op；
- 就绪闭环：`_transfer_kv_cache_all_groups` 完成 → `DONE_RECVING_MSG`/ACK →
  `get_finished()` → `finished_recving` → scheduler 下轮提升请求。

## 7. 不确定点

- 旧 `(engine_id, handshake_port)` 缓存**没有主动清理逻辑**；只有顶层 `SizedDict`
  按 engine_id 数量 FIFO 淘汰（`max_size=16000`），同一 engine_id 下的旧 port 条目会长期残留；
- 若 P 轮换后的 engine_id 恰等于 D 的 `local_engine_id`（例如 1），握手 assert 会失败，
  轮换策略必须避开；
- `use_hybrid` 若为 false，会走 `_transfer_kv_cache` 非 hybrid 路径而非
  `_transfer_kv_cache_all_groups`，时序图需替换；
- P 端发送完成由 D 的 `DONE_RECVING_MSG` 驱动，静态无法确定发送完成回传的步数上限；
- 传输失败/超时的重试策略未实跑验证。
