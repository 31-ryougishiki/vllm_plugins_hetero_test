# PD 分离测试场景（MooncakeHybridConnector）

本目录提供两个 PD 分离测试场景：

- 场景 1：prefill 节点坏 1 卡转异构，decode 节点保持不变；
- 场景 2：decode 节点坏 1 卡缩容，prefill 节点保持不变。

脚本风格参考 `hetero_cp/run_script_hetero/`：

- `hetero_cp/run_script_hetero/prefill/*` 对应 P 端异构启动方式；
- `hetero_cp/run_script_hetero/decode/*` 对应 D 端 `dp16/tp1` 启动方式；
- `hetero_cp/run_script_hetero/proxy.sh` + `load_balance_proxy_server_example.py`
  对应本目录的 PD 负载均衡代理。

差异点：hetero_cp 是**启动期异构**；vllm_plugins 的测试路径是
**对称 DP4TP4 启动 → 运行时触发 DP4TP(3,4,4,4) 重启**。

## 目录内容

```text
pd_hetero/
├── README.md
├── run_scenario1.sh                # 场景1编排：P 转异构，D 不变
├── run_scenario2.sh                # 场景2编排：D 坏1卡缩容，P 不变
├── send_pd_request.py              # 经代理发请求并保存/校验输出
├── check_decode_unchanged.sh       # 场景1校验 D 端健康且未被重启
├── decode/
│   ├── launch_decode_pd.sh         # D 节点启动 dp16/tp1
│   └── trigger_decode_fault.sh     # 场景2触发 D 端 dp16 -> dp15
└── proxy/
    ├── start_proxy_pd.sh           # P 节点启动 PD 代理
    └── load_balance_proxy_server.py
```

## 拓扑

```text
prefill 节点（16 NPU）                 decode 节点（16 NPU）
  初始：DP4TP4（对称）                   始终：DP16TP1（不重启）
  触发后：DP4TP(3,4,4,4)                仅通过 Mooncake 恢复 KV 链
  全局 world_size 16 -> 15              world_size 16 不变
```

- P 端端口：vLLM `9000..9003`，ITS HTTP `8001/8005/8009/8013`；
- D 端端口：vLLM `9100..9115`；
- PD 代理：P 节点 `8000`（可覆盖 `PROXY_PORT`）。

## 使用步骤

### 0. 两个节点都安装 vllm_plugins

P、D 都必须安装 vllm/vllm-ascend v0.23.0 与 vllm_plugins 仓，并设置
`VLLM_CUSTOM_PATCHES=zero_interrupt`（启动脚本已设置）：

```bash
# 每个节点分别执行
cd /opt/its/z30055003/vllm_plugins_hetero_test
bash install_vllm_plugins.sh
```

> D 端不接收策略，但必须加载 zero_interrupt：异构重启后 P 端会轮换
> `engine_id`/handshake_port，D 端依赖 `patch_hetero_mooncake.py` 重新拉取
> 远端元数据，否则续推链路无法恢复。

代理依赖 `fastapi` / `httpx` / `uvicorn`（参考
`load_balance_proxy_server.py` 头部说明），缺少时先安装：  
`pip install "fastapi<0.124.0" httpx uvicorn`

### 1. 拉起服务：D 与 P 可以并发，不必先等 D 就绪

两个节点模型加载都很慢，**推荐同时拉起**。P 端 `run_scenario1.sh`
会先拉起对称 prefill，然后在需要发基线请求前等待 16 个 decode engine
健康；D 端晚一点就绪只会推迟“基线请求”这一步，不会导致服务启动失败。

D 节点执行：

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test/pd_hetero
nohup bash decode/launch_decode_pd.sh \
  > /opt/its/z30055003/logs/decode/launch.log 2>&1 &
```

紧接着在 P 节点执行：

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test/pd_hetero
DECODE_HOST=<decode-node-ip> \
nohup bash run_scenario1.sh \
  > /opt/its/z30055003/logs/pd_scenario1/run.log 2>&1 &
```

不需要等 D 的 `/health` 全部通过后再启动 P；两边各自加载模型，
场景脚本只会在“发第一个请求”和“触发异构重启”之前等待两端就绪。

### 2. 场景 1 自动执行内容

脚本自动完成：

1. 启动对称 P（`../launch_prefill_hetero_test.sh`，若已健康则跳过）；
2. 等待 D 端 16 个 engine 健康；
3. 启动 PD 代理（端口 8000）；
4. 经代理发**基线请求**并保存
   `logs/pd_scenario1/pre_hetero.json`；
5. 调用 `../trigger_hetero_restart.sh` 只向 P 的 4 个 executor 下发
   `PD_REBUILD` 异构策略；
6. 等待 4 个 DP 的 `/health`、`Full-restart barrier passed` 与
   `KV connector metadata updated successfully`；
7. 确认 D 端 16 个 engine 仍健康；
8. 经代理发**复测请求**并保存
   `logs/pd_scenario1/post_hetero.json`；
9. 对比两次 `choices[0].text`，默认要求完全一致。

### 3. 校验 D 端确实未重启

```bash
# D 与 P 同节点时
bash check_decode_unchanged.sh

# D 在远端时
SSH_DECODE="root@<decode-node-ip>" \
DECODE_HOST=<decode-node-ip> \
bash check_decode_unchanged.sh
```

校验项：16 个 `/health` 均为 200，且 decode 日志中不存在
`restarting workers of EVERY DP instance`。

## 场景 2：decode 坏 1 卡，prefill 保持不变

拓扑变化：D 端 `DP16TP1 -> DP15TP1`（默认故障 NPU 15），P 端始终保持对称
`DP4TP4`，不接收任何策略。

### 执行步骤

D 节点先启动 decode（与场景 1 相同，可并发启动）：

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test/pd_hetero
nohup bash decode/launch_decode_pd.sh \
  > /opt/its/z30055003/logs/decode/launch.log 2>&1 &
```

P 节点执行场景编排，默认通过 SSH 触发 D 端故障脚本：

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test/pd_hetero
SSH_DECODE="root@<decode-node-ip>" \
DECODE_HOST=<decode-node-ip> \
DECODE_FAULT_NPU=15 \
nohup bash run_scenario2.sh \
  > /opt/its/z30055003/logs/pd_scenario2/run.log 2>&1 &
```

没有 SSH 时，在 D 节点手动执行：

```bash
DECODE_FAULT_NPU=15 bash decode/trigger_decode_fault.sh
```

然后 P 节点以 `TRIGGER_MODE=skip` 运行 `run_scenario2.sh`。

### 场景 2 自动执行内容

1. 确认 P 对称 `DP4TP4` 与 D 初始 `DP16TP1` 健康；
2. 基线请求（`pre_decode_fault.json`）；
3. 记录 P 端 restart 日志条数（用于证明 P 未被重启）；
4. 触发 D 端故障：16 个 decode executor 全部收到 `PD_REBUILD`，
   故障 executor 缩到 `new_dp=0/new_tp=0`，其余 `new_dp=15`；
5. 等待 D 端 15 个健康 engine 恢复；
6. 从代理摘除故障 decoder；
7. PD 链路预热，发复测请求（`post_decode_fault.json`）；
8. 对比两次输出，默认要求完全一致；
9. 确认 P 端日志没有新增 restart 记录。

## 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DECODE_HOST` | 必填 | decode 节点 IP |
| `DECODE_VLLM_PORT_START` | 9100 | D 端 vLLM 起始端口 |
| `DECODE_DP_SIZE` | 16 | D 端初始 DP 数 |
| `VLLM_PORT_START` | 9000 | P 端 vLLM 起始端口 |
| `PROXY_PORT` | 8000 | PD 代理端口 |
| `FAULT_NPU` | 3 | 场景1故障卡，必须在 DP0 的 NPU 0..3 |
| `DECODE_FAULT_NPU` | 15 | 场景2故障卡，范围 0..15 |
| `TRIGGER_MODE` | ssh | 场景2触发方式：ssh / local / skip |
| `SSH_DECODE` | 空 | 场景2通过 SSH 触发 D 端时必填，如 `root@ip` |
| `REQUIRE_OUTPUT_MATCH` | 1 | 1=异构前后输出必须完全一致；0=仅要求非空 |
| `REQUEST_TEMPERATURE` / `REQUEST_SEED` | 0.0 / 1024 | 请求采样参数；0=贪心解码，保证两次独立请求可比较 |
| `WARMUP_REQUESTS` | 场景1=16；场景2 基线=16、降级后=15 | 预热成功请求数，覆盖全部 decoder，避免只 warmup 第一个 decoder |
| `WARMUP_RETRIES` / `WARMUP_INTERVAL` | 30 / 10 | 预热失败/仍 recompute 时的额外重试次数与间隔 |
| `START_PREFILL` / `START_PROXY` | 1 | 编排脚本是否自动拉起 P / 代理 |
| `RESTART_TIMEOUT` | 900 | 等待全量重启/KV 恢复的超时秒数 |

## 结果与排障

```bash
# 场景主日志
tail -f /opt/its/z30055003/logs/pd_scenario1/run.log
grep -E "RESULT_TEXT|MATCH|PASS|FAIL" /opt/its/z30055003/logs/pd_scenario1/run.log

# P 端重启关键字
grep -R "Full-restart barrier passed" /opt/its/z30055003/logs/prefill/
grep -R "KV connector metadata updated" /opt/its/z30055003/logs/prefill/

# D 端确认未重启
bash check_decode_unchanged.sh
```

清理进程：

```bash
# P 节点
pkill -f "vllm serve /opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self" || true
pkill -f load_balance_proxy_server.py || true

# D 节点（通过 SSH 或登录 D 节点执行）
pkill -f "vllm serve /opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self" || true
```
