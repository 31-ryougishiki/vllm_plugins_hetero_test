# 推理细节 05：Scheduler ↔ KV connector ↔ model_runner 状态机

聚焦 D 端收到 `kv_transfer_params` 后，请求如何从 `WAITING_FOR_REMOTE_KVS`
推进到可执行，以及 P 端如何生成并延迟释放远程 KV。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| scheduler 分配块后通知 connector | `origin_0.23.0/vllm/vllm/v1/core/sched/scheduler.py:783-801` |
| 置 `WAITING_FOR_REMOTE_KVS` | `scheduler.py:804-824` |
| 构建 connector metadata | `scheduler.py:955-972` |
| 输出阶段处理 finished_recving/sending | `scheduler.py:2221-2248` |
| 唤醒 waiting 请求 | `scheduler.py:2188-2203` |
| P 端 request_finished 生成 kv_transfer_params | `scheduler.py:2096-2128` |
| connector request_finished_all_groups | `origin_0.23.0/vllm-ascend/vllm_ascend/distributed/kv_transfer/kv_p2p/mooncake_hybrid_connector.py:1418-1465` |
| connector update_state_after_alloc | `mooncake_hybrid_connector.py:1367-1389` |
| connector build_connector_meta | `mooncake_hybrid_connector.py:1390-1417` |
| worker start_load_kv | `mooncake_hybrid_connector.py:1770-...` |
| model runner KV 生命周期 | `origin_0.23.0/vllm/vllm/v1/worker/kv_connector_model_runner_mixin.py:36-113` |
| model_runner 无前向时调用 KV connector | `origin_0.23.0/vllm-ascend/vllm_ascend/worker/model_runner_v1.py:2060-2090` |
| 前向时获取 KV connector output | `model_runner_v1.py:2311-2316` |

## 2. 进程与线程

- 状态机跨 3 个进程：D EngineCoreProc（scheduler + connector scheduler）、
  D ITSNPUWorker（connector worker + `KVCacheRecvingThread`）、P 侧对应进程；
- 远程传输由 worker 内线程异步进行，scheduler 通过 `KVConnectorOutput` 的
  `finished_recving/finished_sending` 感知完成。

## 3. HTTP 请求

本状态机不新增 HTTP；输入是 D 请求携带的 `kv_transfer_params`：
`do_remote_prefill=true, remote_host/port, remote_engine_id, remote_block_ids` 等。

## 4. 环境变量

`kv_transfer_config`（`kv_role=kv_consumer`、`kv_port`、`engine_id`）、
`ASCEND_CONNECT_TIMEOUT/ASCEND_TRANSFER_TIMEOUT/MC_TRANSFER_TIMEOUT`。

## 5. 状态流转

### 5.1 D 端

```text
EngineCoreRequest(ADD, kv_transfer_params)
  → scheduler.add_request（:1801-1823；connector.on_new_request :1820-1821）
  → schedule()：
      connector.get_num_new_matched_tokens（:615-621）
      load_kv_async 时 num_new_tokens=0，分配块但延迟缓存（:675-678,754-772）
      connector.update_state_after_alloc（:787-792）
      request.status = WAITING_FOR_REMOTE_KVS（:803-824）
      构建 scheduler_output.kv_connector_metadata（:954-956,969-972）
  → model_runner.execute_model：
      无前向时（num_scheduled_tokens==0）：
        kv_connector_no_forward（model_runner_v1.py:2060-2090）
          → KVConnectorModelRunnerMixin._get_kv_connector_output
              bind_connector_metadata（mixin:89）
              connector.start_load_kv(get_forward_context())（mixin:95）
              wait_for_save（Mooncake 实际为 no-op，mooncake_hybrid_connector.py:1148-1150）
              输出 finished_recving/finished_sending（mixin:102-104）
      有前向时：
        maybe_get_kv_connector_output(...) 包裹模型前向（mixin:51-61,77-112）
  → ModelRunnerOutput 回到 scheduler.update_from_output：
      _update_from_kv_xfer_finished（scheduler.py:1596-1597,2221-2248）
        finished_recving → finished_recving_kv_req_ids.add(req_id)
  → 下一轮 schedule：
      _try_promote_blocked_waiting_request（:577-586,2188-2203）
        WAITING_FOR_REMOTE_KVS 且已 finished_recving
        → _update_waiting_for_remote_kv（:2154-2186）
        → status=WAITING（有 preemption 则 PREEMPTED）
  → 正常分配 blocks，status=RUNNING，执行真正 decode 前向
```

### 5.2 P 端

```text
P 请求停止：
  scheduler._handle_stopped_request → _free_request（:1519-1526,1888-1905）
  → _connector_finished（:2099-2128）
      MooncakeConnectorScheduler.request_finished_all_groups（mooncake_hybrid_connector.py:1418-1464）
        条件：params.do_remote_decode=true 且 FINISHED_LENGTH_CAPPED
        → delay_free_blocks + kv_transfer_params{
            do_remote_prefill=true, do_remote_decode=false,
            remote_block_ids, remote_engine_id, remote_request_id,
            remote_host, remote_port(side_channel_port),
            remote_ptp_size, last_token_id,
            remote_multi_nodes_meta_mapping, num_prompt_blocks
          }
  → kv_transfer_params 进入 EngineCoreOutput → RequestOutput → CompletionResponse
P 端延迟释放：
  worker start_load_kv 时 kv_send_thread.add_delayed_request
  → KVCacheSendingThread 完成后 get_finished → finished_sending
  → D 回传/下次 update_from_output 时 scheduler._free_blocks
```

### 5.3 状态表

| 状态 | 进入条件 | 退出条件 |
|---|---|---|
| `WAITING` | 新请求/被提升 | scheduler 分配块并 async load |
| `WAITING_FOR_REMOTE_KVS` | `load_kv_async` 且完成分配 | worker 报 `finished_recving` |
| `RUNNING` | 远程 KV 就绪或本地 prefill | 请求完成/preempt |
| `FINISHED` | 采样/停止条件满足 | 输出并释放块 |

Mooncake scheduler 内部集合：

| 集合 | 位置 | 含义 |
|---|---|---|
| `_reqs_need_recv` | `mooncake_hybrid_connector.py:1210,1375-1382` | D 本步待拉取请求 |
| `_reqs_need_send` | `mooncake_hybrid_connector.py:1211,1448` | P 延迟释放块请求 |
| `_reqs_in_batch` | `mooncake_hybrid_connector.py:1212,1376` | 本步参与 KV transfer 的请求 |

## 6. 异构重启后的变化

- P 全量重启后 engine_id 轮换、handshake_port 变化；
- D 请求携带的新 `kv_transfer_params` 指向新 engine_id；connector worker 在
  `start_load_kv → _get_remote_metadata` 按新 `(engine_id, handshake_port)`
  重新握手并填充缓存（详见 `04_kv_transfer_timeline.md`）；
- scheduler 状态机本身不变，变化发生在 connector worker 缓存层。

## 7. 不确定点

- `load_kv_async` 的最终取值取决于 connector 配置与 scheduler 参数，未实跑确认；
- **`wait_for_save` 对 Mooncake 是 no-op**（`mooncake_hybrid_connector.py:1148-1150`）；
  发送完成完全依赖 `KVCacheSendingThread` 的 finished 集合在后续某步被 `get_finished`
  取回，静态无法确定延迟释放的步数上限；
- `finished_recving` 由 worker 侧线程信号经 ModelRunnerOutput 回传，请求仍停留在
  `WAITING_FOR_REMOTE_KVS` 直到下一轮 `schedule` 才提升，因此“已就绪”与“可执行”
  之间至少一个 engine step 延迟；
- P 端 `request_finished_all_groups` 要求 `params.do_remote_decode=true` 且
  `FINISHED_LENGTH_CAPPED`；该字段由 proxy 注入，引擎内不生成；
- 若 KV connector 初始化失败或未配置，`EngineCore.add_request` 只告警
  （`core.py:364-370`），请求不会进入该状态机；
- 若传输失败，`invalid_block_ids` 路径会调整 `num_computed_tokens`，静态未展开
  `_update_requests_with_invalid_blocks` 全部细节。
