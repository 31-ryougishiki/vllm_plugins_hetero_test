# 阶段 04：触发

覆盖手动直连 executor 的 4 个 trigger 脚本、SSH/local 执行路径，以及 DC 触发/修复接口。
本阶段只负责“把策略送达”，策略执行见 `05_restart_recovery.md`。

## A. 手动触发 P 异构（P1 使用）

### 1. 代码行号

- `pd_hetero/run_scenario1.sh:174-188` 调用 trigger；
- `trigger_hetero_restart.sh:49-165` 内嵌 Python 构造并 POST；
- payload 构造：`trigger_hetero_restart.sh:77-101`（engine config）、`:103-127`（NPU health）；
- HTTP 循环：`trigger_hetero_restart.sh:130-158`。

### 2. 进程与线程

- 新增 1 个临时 `python3` 进程执行 trigger，结束后退出；
- P/D 服务进程本阶段不变；P worker 的退出/重建在阶段 05。

### 3. HTTP 请求

```text
POST http://127.0.0.1:{8001,8005,8009,8013}/api/v1/executor/deploy
```

payload 关键字段：

```json
{
  "deploy_type": "PD_REBUILD",
  "executor_id": "0..3",
  "engine_parallel_config": [
    {"executor_id":"0","dp":4,"tp":4,"data_parallel_rank":0,
     "new_dp":4,"new_tp":3,"tp_asymmetric_shardings":[2,1,1]},
    {"executor_id":"1..3","dp":4,"tp":4,
     "new_dp":4,"new_tp":4,"tp_asymmetric_shardings":null}
  ],
  "engine_npu_healthy_state": [ {"server_list":[{"host_ip":"<P IP>",
      "device":[ {"npu_id":0..15,"npu_healthy": npu!=3} ]}]} ]
}
```

### 4. 环境变量

`LOCAL_IP`、`ITS_HTTP_PORT_START=8001`、`DP_SIZE=4`、`TP_SIZE=4`、`NUM_NPUS=16`、
`FAULT_NPU=3`、`SIMULATE_FAULT=true`（可由外部覆盖）、`DEPLOY_TYPE=PD_REBUILD`（默认，可覆盖）。

### 5. 调用链

```text
run_scenario1.sh
  → bash trigger_hetero_restart.sh
      python3 内嵌脚本
        for executor_id in 0..3:
          urllib POST 127.0.0.1:<8001+id*4>/api/v1/executor/deploy
```

## B. 手动触发 D 缩容（P3/P7 使用）

### 1. 代码行号

- P3 远端执行：`common.sh:250-276 trigger_decode_remote`；
- P7 本机执行：`run_decode_fault_alone.sh:171-186`；
- trigger 脚本：`decode/trigger_decode_fault.sh:58-191`（payload 与 POST）；
- 等待 barrier/health：`trigger_decode_fault.sh:211-253`。

### 2. 进程与线程

- P3：P 节点 1 个临时 `ssh` 进程；D 节点执行 1 个临时 `bash`+`python3` 进程；
- P7：D 节点本机 1 个临时 `bash`+`python3`；
- D 服务进程本阶段不变。

### 3. HTTP 请求

```text
POST http://127.0.0.1:18001..18016/api/v1/executor/deploy
```

payload：

```json
{
  "deploy_type": "PD_REBUILD",
  "executor_id": "0..15",
  "engine_parallel_config": [
    {"executor_id":"0..14","dp":16,"tp":1,
     "new_dp":15,"new_tp":1,"tp_asymmetric_shardings":null},
    {"executor_id":"15","dp":16,"tp":1,
     "new_dp":0,"new_tp":0,"tp_asymmetric_shardings":null}
  ],
  "engine_npu_healthy_state": [ { "device":[ {"npu_id":0..15,
      "npu_healthy": npu!=15} ] } ]
}
```

### 4. 环境变量

`LOCAL_IP`、`DECODE_DP_SIZE=16`、`DECODE_ITS_PORT_START=18001`、
`DECODE_VLLM_PORT_START=9100`、`DECODE_FAULT_NPU=15`、`DECODE_LOG_DIR`、
`DEPLOY_TYPE=PD_REBUILD`、`RESTART_TIMEOUT=900`。

### 5. 调用链

```text
P3: run_scenario2.sh → common.sh:trigger_decode_remote fault
      ssh SSH_DECODE "cd DECODE_TEST_DIR && bash decode/trigger_decode_fault.sh"
P7: run_decode_fault_alone.sh → bash decode/trigger_decode_fault.sh
  → python3 内嵌脚本 for rank 0..15 POST ITS /deploy
  → 故障 rank15 连接失败仅告警
  → 等待 rank0..14 的 restart marker 与 15 个 /health
```

## C. 手动触发 P RECOVER（P5 使用）

### 1. 代码行号

- `run_scenario3.sh:191-203`；
- `trigger_prefill_recover.sh:63-78`（engine config）、`:80-104`（全健康 NPU）、`:106-135`（POST）。

### 2. 进程与线程

- P 节点 1 个临时 `python3` 进程；
- 4 个 P executor 收到策略；worker 重建在阶段 05。

### 3. HTTP 请求

```text
POST http://127.0.0.1:{8001,8005,8009,8013}/api/v1/executor/deploy
deploy_type=RECOVER
engine_parallel_config: 4 条 dp=4,tp=4,new_dp=4,new_tp=4,shardings=null
engine_npu_healthy_state: 16 个 NPU 全 healthy
```

### 4. 环境变量

`LOCAL_IP`、`ITS_HTTP_PORT_START=8001`、`DP_SIZE=4`、`TP_SIZE=4`、`NUM_NPUS=16`、
`DEPLOY_TYPE=RECOVER`。

### 5. 调用链

```text
run_scenario3.sh → bash trigger_prefill_recover.sh → for id 0..3 POST ITS /deploy
```

## D. 手动触发 D RECOVER（P5/P8 使用）

### 1. 代码行号

- P5 远端：`run_scenario3.sh:232-239` → `common.sh:250-276`；
- P8 本机：`run_decode_recover_alone.sh:136-148`；
- `trigger_decode_recover.sh:82-94`（payload）、`:96-118`（NPU health）、`:122-155`（POST）、`:177-211`（等待）。

### 2. 进程与线程

- P5：P 节点 1 个 `ssh` 进程；D 节点临时 `bash`+`python3`；
- P8：D 本机临时 `bash`+`python3`。

### 3. HTTP 请求

```text
POST http://127.0.0.1:18001..18016/api/v1/executor/deploy
deploy_type=RECOVER
engine_parallel_config: 16 条 dp=16,tp=1,new_dp=16,new_tp=1,shardings=null
engine_npu_healthy_state: 16 个 NPU 全 healthy
```

### 4. 环境变量

同 D 缩容；`DEPLOY_TYPE=RECOVER`。

### 5. 调用链

```text
P5: run_scenario3.sh → common.sh:trigger_decode_remote recover
      ssh SSH_DECODE "bash decode/trigger_decode_recover.sh"
P8: run_decode_recover_alone.sh → bash decode/trigger_decode_recover.sh
  → 16 次 POST ITS /deploy
  → 等待 16 个 restart marker + 16 个 /health
```

## E. DC 触发故障（P2/P4 使用）

### 1. 代码行号

- wrapper：`decision_center/run_scenario1_dc.sh:20-39`、`run_scenario2_dc.sh:20-36`；
- 编排调用：`run_scenario1.sh:163-173`、`run_scenario2.sh:190-199`；
- 封装：`common.sh:236-240`；
- 测试脚本：`decision_center/trigger_fault.sh:31-55`；
- DC 接口实现：`DecisionMakingCenter/decision_center/api.py:977-1050`。

### 2. 进程与线程

- P 节点 1 个临时 `python3` 进程 POST DC；
- DC 进程内：接口线程 → service fault queue → 异步 fault handler 计算并下发策略；
- executor 侧本阶段只收到策略。

### 3. HTTP 请求

```text
POST <DECISION_CENTER_URL>/api/v1/decision_center/test/trigger_fault
{"node_ip":"<P或D IP>","npu_id":"3或15","fault_code":"80E78000"}
```

DC→executor 由 DC 侧 `deploy_to_executor` 发出（`DecisionMakingCenter/decision_center/api.py:501-514`）：

```json
{
  "deploy_type": "DEGRADE",          // 当前 DC 代码实际结果
  "executor_id": "<exe-...>",
  "service_id": "<VLLM_SERVICE_ID>",
  "engine_parallel_config": [ ... ], // 不含 tp_asymmetric_shardings
  "engine_npu_healthy_state": [ ... ]
}
```

### 4. 环境变量

`DECISION_CENTER_URL`（默认 `http://7.246.78.79:8088`，可覆盖）、
`FAULT_CODE=80E78000`、`FAULT_NODE_IP`/`FAULT_NPU`。

### 5. 调用链（测试侧）

```text
run_scenario*.sh
  → common.sh:dc_trigger_fault
    → decision_center/trigger_fault.sh
        urllib POST DC /test/trigger_fault
```

DC 侧（源码确认，非本次运行路径范围但决定 executor 输入）：

```text
api.py:trigger_test_fault
  → 解析 fault 列表、标记 NPU 不健康
  → 按 service 分组、放入 fault queue
  → main.py 策略回调
      process_service → 只筛选坏卡 engine 的 executor
      strategy_optimizer 计算 new_tp/new_dp
      send_exec_strategy → deploy_type 规则 main.py:552-558
      deploy_to_executor → POST 各 executor /api/v1/executor/deploy
```

## F. DC 修复（P6 使用）

### 1. 代码行号

- wrapper：`decision_center/run_scenario3_dc.sh:22-45`；
- 合并上报：`run_scenario3.sh:176-190`；
- 封装：`common.sh:243-247`；
- 测试脚本：`decision_center/repair_devices.sh:35-61`；
- DC 接口：`DecisionMakingCenter/decision_center/api.py:537-606`；
- DC 恢复下发：`state_monitor.py:896-1027`。

### 2. 进程与线程

- P 节点 1 个临时 `python3` POST DC；
- DC 状态监控线程检查服务全健康后调用恢复流程，向坏卡 engine 的所有 executor 下发 RECOVER。

### 3. HTTP 请求

```text
POST <DC>/api/v1/decision_center/repair/devices
[
  {"node_ip":"<P IP>","npu_id":"3"},
  {"node_ip":"<D IP>","npu_id":"15"}
]
```

DC→executor：`deploy_type=RECOVER`，每个坏卡 engine 的 executor 收到本 engine 全部配置。

### 4. 环境变量

`DECISION_CENTER_URL`、`FAULT_NODE_IP`/`FAULT_NPU`、`DECODE_HOST`/`DECODE_FAULT_NPU`、
`RECOVER_TARGET=both`。

### 5. 调用链（测试侧）

```text
run_scenario3.sh
  → dc_repair_devices "P_IP:3" "D_IP:15"
    → repair_devices.sh POST DC /repair/devices（一次）
  → DC_REPAIR_SENT=1，D 分支不再发第二次
```

## G. 触发阶段的公共不确定点

- P2/P4/P6 的 executor payload 由 DC 生成；测试脚本只固定 DC 输入，不固定策略细节；
- DC `fault_code=80E78000` 必须被 `FAULT_CODE_CONFIG` 支持，否则接口 200 但故障被静默过滤；
- 手动 P1 的 `SIMULATE_FAULT`/`DEPLOY_TYPE` 可由外部环境覆盖；
- D 缩容时故障 executor15 的 POST 失败只告警，不保证 rank15 收到缩零策略；
- DC 修复只有在 DC 此前记录 `bad_engines` 时才会真正下发 RECOVER。
