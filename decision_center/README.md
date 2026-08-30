# 决策中心触发脚本

决策中心已部署在 `http://7.246.78.79:8088`。本目录脚本不再直接向
executor 的 ITS HTTP 端口 POST 策略，而是通过决策中心接口触发。

> 决策中心方式不是新增场景，而是对 **场景 1 / 场景 2 / 场景 3** 的
> 另一种触发方式。三个场景的拓扑定义见
> `pd_hetero/README.md`；`hetero_cp` 只适配场景 1，不适用于这里的
> 场景 2/3 对照。

| 操作 | 决策中心接口 |
|---|---|
| 触发故障（扩/缩容） | `POST /api/v1/decision_center/test/trigger_fault` |
| 上报坏卡修复（RECOVER） | `POST /api/v1/decision_center/repair/devices` |
| 决策中心健康检查 | `GET /api/v1/decision_center/health` |

当前节点：

- prefill：`7.246.78.75`（DP4TP4，4 executor）
- decode：`7.246.78.76`（DP16TP1，16 executor）
- 决策中心：`7.246.78.79:8088`

P/D 的 **20 个 executor 必须使用同一个 `VLLM_SERVICE_ID`**（默认
`pd-hetero-service`），否则决策中心会把它们注册成多个服务，无法在同一
服务内计算 PD 扩缩容 / RECOVER。

## 1. 安装与拉起

两个节点都安装最新 vllm_plugins wheel 后，分别在对应节点执行：

> 合并后的 vllm_plugins 默认走 0829 实现；DeepSeek-V4 / 决策中心场景
> 必须使用 `VLLM_ITS_DEEPSEEK_V4=1`。`install_vllm_plugins.sh` 与
> `launch_*_dc.sh` 已默认设置该值，安装期与运行期保持一致。

```bash
# prefill 节点 7.246.78.75
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash decision_center/launch_prefill_dc.sh \
  > /opt/its/z30055003/logs/launch_prefill_dc.log 2>&1 &

# decode 节点 7.246.78.76
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash decision_center/launch_decode_dc.sh \
  > /opt/its/z30055003/logs/launch_decode_dc.log 2>&1 &
```

两个脚本内部会：

1. 设置 `VLLM_ITS_DECISION_CENTER_URL=http://7.246.78.79:8088`；
2. 设置统一 `VLLM_SERVICE_ID=pd-hetero-service`；
3. 设置 `VLLM_ITS_DEEPSEEK_V4=1`（DeepSeek-V4 patch 族）；
4. 等待本节点全部 engine 的 `/health` 就绪。

确认决策中心已经看到全部 executor：

```bash
curl http://7.246.78.79:8088/api/v1/decision_center/health
# 决策中心日志应出现 20 次 /init_executor_state，并给每个 executor
# 分配 exe-<service_id>-<engine_uid>-<n> 形式的 executor_id。
```

## 2. 场景 1：prefill 坏卡转异构（决策中心触发）

```bash
# prefill 节点
cd /opt/its/z30055003/vllm_plugins_hetero_test
DECODE_HOST=7.246.78.76 \
nohup bash decision_center/run_scenario1_dc.sh \
  > /opt/its/z30055003/logs/pd_scenario1_dc/run.log 2>&1 &
```

等价的手动触发命令（只触发，不做请求校验）：

```bash
bash decision_center/trigger_fault.sh 7.246.78.75 3
```

决策中心会把 NPU 3 标记为故障，向 P 的 4 个 executor 下发 DEGRADE，
目标 `DP4TP(3,4,4,4)`；D 不接收策略。

## 3. 场景 2：decode 坏卡缩容（决策中心触发）

```bash
# prefill 节点
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash decision_center/run_scenario2_dc.sh \
  > /opt/its/z30055003/logs/pd_scenario2_dc/run.log 2>&1 &
```

等价的手动触发命令：

```bash
bash decision_center/trigger_fault.sh 7.246.78.76 15
```

决策中心把 D 的 executor 15 缩到零，其余 decode executor 重启到
`DP15TP1`；P 不接收策略。

## 4. 场景 3：RECOVER（决策中心触发）

场景 1/2 执行完后，**一次调用 repair 接口上报服务下所有坏卡**：

```bash
# prefill 节点
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash decision_center/run_scenario3_dc.sh \
  > /opt/its/z30055003/logs/pd_scenario3_dc/run.log 2>&1 &
```

等价的手动恢复命令：

```bash
# 两张坏卡一起上报，决策中心确认服务无坏卡后自动下发 RECOVER
bash decision_center/repair_devices.sh 7.246.78.75:3 7.246.78.76:15
```

决策中心会向 P 下发 `DP4TP(3,4,4,4) -> DP4TP4` 的 RECOVER，向 D 下发
`DP15TP1 -> DP16TP1` 的 RECOVER；脚本随后把恢复的 decoder 加回代理并
对比输出。

只恢复单侧：

```bash
RECOVER_TARGET=prefill bash decision_center/run_scenario3_dc.sh
RECOVER_TARGET=decode  bash decision_center/run_scenario3_dc.sh
```

## 5. 全流程

```bash
DECODE_HOST=7.246.78.76 \
nohup bash decision_center/run_all_dc.sh \
  > /opt/its/z30055003/logs/decision_center_all.log 2>&1 &
```

顺序：场景 1 → 场景 2 → 场景 3。

## 6. 排障

```bash
# 决策中心健康
curl http://7.246.78.79:8088/api/v1/decision_center/health

# executor 是否注册（决策中心日志）
grep -R "添加executor" /path/to/decision-center/log/

# executor 侧日志：必须出现 assigned executor_id
grep -R "assigned executor_id" /opt/its/z30055003/logs/prefill/*.log
grep -R "assigned executor_id" /opt/its/z30055003/logs/decode/*.log

# 策略下发日志
grep -R "Received deployment strategy" /opt/its/z30055003/logs/prefill/*.log
grep -R "Full-restart barrier passed" /opt/its/z30055003/logs/decode/*.log
```

> 手动 `trigger_hetero_restart.sh` / `trigger_prefill_recover.sh` /
> `trigger_decode_fault.sh` 仍可用于无决策中心的环境；二者发送的
> executor_id 是本地 `data_parallel_rank` 数字，插件 HTTP 端同时接受
> 数字 id 与决策中心分配的 `exe-...` id。
