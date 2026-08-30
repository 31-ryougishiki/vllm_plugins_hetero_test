# 阶段 02：健康检查 / 代理

覆盖场景编排脚本对 P/D/proxy 的健康检查，以及 PD 代理的启动与实例管理。

## 1. 代码行号

| 步骤 | 文件:行号 |
|---|---|
| `check_http` | `pd_hetero/common.sh:31-47` |
| `wait_http` | `common.sh:50-66` |
| `all_http_ready` | `common.sh:87-100` |
| P 健康检查 | `run_scenario1.sh:105-118`；`run_scenario2.sh:116-129`；`run_scenario3.sh:148-151` |
| D 健康检查 | `run_scenario1.sh:123-127`；`run_scenario2.sh:134-138`；`run_scenario3.sh:152-161` |
| proxy 启动/复用 | `run_scenario1.sh:132-142`；`run_scenario2.sh:143-153`；`run_scenario3.sh:162` |
| proxy 启动脚本 | `pd_hetero/proxy/start_proxy_pd.sh:23-67` |
| proxy 实例表初始化 | `proxy/load_balance_proxy_server.py:502-514` |
| `/healthcheck` | `load_balance_proxy_server.py:895-901` |
| `/instances/add|remove` | `load_balance_proxy_server.py:904-911` |
| 实例增删实现 | `load_balance_proxy_server.py:838-872,333-401` |
| D 单机健康检查 | `decode/run_decode_fault_alone.sh:94-119`；`run_decode_recover_alone.sh:90-104` |
| P ITS 健康预检 | `run_scenario1.sh:156-160`；`run_scenario3.sh:169-173` |

## 2. 进程与线程

- 本阶段不新增长驻进程；只有健康探测用的临时 `python3` 进程。
- 若 proxy 未运行，由 `start_proxy_pd.sh` 启动 **1 个常驻 proxy 进程**
  （`uvicorn.run`，`load_balance_proxy_server.py:917-919`）。
- proxy 内部：FastAPI lifespan 初始化 `ProxyState`，维护 prefill/decode 实例表和两个 heap。

## 3. HTTP 请求

| 端点 | 方法 | 检查内容 |
|---|---|---|
| `http://127.0.0.1:9000+i/health` | GET | P engine 200 |
| `http://<DECODE_HOST>:9100+i/health` | GET | D engine 200 |
| `http://127.0.0.1:8000/healthcheck` | GET | proxy 200，返回 prefill/decode 实例数 |
| `http://127.0.0.1:8001/8005/8009/8013/health` | GET | P ITS HTTP 200（触发前预检） |
| `http://127.0.0.1:8000/instances/add` | POST | body `{"type":"decode","instances":"host:port"}` |
| `http://127.0.0.1:8000/instances/remove` | POST | 同上，摘除故障 decoder |

## 4. 环境变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `PROXY_HOST/PROXY_PORT` | `127.0.0.1` / `8000` | 代理地址/端口 |
| `PREFILL_HOST` | `127.0.0.1` | 代理连接 P |
| `PREFILL_VLLM_PORT_START` | 9000 | P 起始端口 |
| `DECODE_HOST` | 必填 | D 节点 IP |
| `DECODE_VLLM_PORT_START` | 9100 | D 起始端口 |
| `DECODE_DP_SIZE` | 16 | 代理初始 D 实例数 |
| `PYTHON_BIN` | python3 | 健康检查与 proxy 解释器 |
| `START_PREFILL/START_PROXY` | 1 | 是否自动拉起；P6 wrapper 为 0 |

## 5. 函数调用链

```text
run_scenario*.sh
  → common.sh:all_http_ready / wait_http / check_http
      python3 urllib（禁用系统代理）→ /health
  → proxy 未就绪时：
      start_proxy_pd.sh
        → load_balance_proxy_server.py:main
            uvicorn.run(app)
            → lifespan: ProxyState(prefiller_instances, decoder_instances)
  → proxy 就绪后：
      wait_http proxy /healthcheck
```

实例增删（S2/S3 使用）：

```text
proxy_instance.py:main
  → POST /instances/add 或 /instances/remove
    → _handle_adjust_instances
        → ProxyState.add_instances
            → add_decoders/add_prefillers（heap push）
        → ProxyState.remove_decoders/remove_prefillers（heap 重建）
```

## 6. 本阶段在 8 条路径中的差异

| 路径 | 差异 |
|---|---|
| P1/P2 | 检查 P 4、D 16、proxy；P ITS 预检 |
| P3/P4 | 检查 P 4、D 16、proxy；无 P ITS 预检；P4 触发后动态探测 D `/health` |
| P5/P6 | 检查 P 4、D 15（跳过 rank15 强校验）、proxy；P ITS 预检 |
| P7 | 只检查 D 16；无 P/proxy |
| P8 | 只检查 D 15 + rank15 idle 日志；无 P/proxy |

## 7. 不确定点

- 健康检查只判断 HTTP 200，不校验实际 DP/TP 拓扑或 patch 族；
- S3 前置检查不验证 P 当前是否确实是异构、rank15 是否确实是 Idle；
- 远端 D 检查依赖 `DECODE_HOST` 网络可达；代理默认连 P 的 127.0.0.1，若 P 与代理
  不同节点需覆盖 `PREFILL_HOST`；
- proxy 实例表初始大小由 `DECODE_DP_SIZE` 决定，与实际运行拓扑不一致时需靠
  S2 的 add/remove 修正。
