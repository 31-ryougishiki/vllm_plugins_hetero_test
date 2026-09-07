# vllm_plugins_hetero_test（minimal）

本目录只保留最简 PD 分离（prefill/decode）异构测试脚本。

```text
.
├── README.md
└── minimal/
    ├── prefill/                  # P 端启动：DP4TP4（kv_producer）
    ├── decode/                   # D 端启动：DP16TP1（kv_consumer）
    ├── proxy/                    # 启动 PD 负载均衡代理
    └── trigger/                  # 触发故障/恢复：直连 executor 或经决策中心
```

## 前置条件

- P、D 节点都已安装 `vllm` / `vllm-ascend` v0.23.0 以及 `vllm_plugins`，并已生效
  `zero_interrupt` 插件；
- 模型路径保持脚本默认值：
  `/opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self`；
- 默认节点 IP：
  - P：`7.246.78.74`
  - D：`7.246.78.76`
  - 决策中心：`http://7.246.78.79:8088`

如果节点 IP 不同，执行时用环境变量覆盖，例如：

```bash
# P 节点
LOCAL_IP=<P节点IP> bash minimal/prefill/start_server.sh

# D 节点
LOCAL_IP=<D节点IP> bash minimal/decode/start_server.sh

# P 节点启动代理
PREFILL_HOST=<P节点IP> DECODE_HOST=<D节点IP> bash minimal/proxy/proxy.sh
```

## 快速测试：P 端异构 DP4TP4 -> DP4TP(3,4,4,4)

1. **P 节点启动 prefill**

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash minimal/prefill/start_server.sh \
  > /tmp/prefill.log 2>&1 &
```

2. **D 节点启动 decode**

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash minimal/decode/start_server.sh \
  > /tmp/decode.log 2>&1 &
```

3. **等待两端健康**（P 9000-9003，D 9100-9115）

```bash
curl -fsS http://<P节点IP>:9000/health
curl -fsS http://<D节点IP>:9100/health
```

4. **P 节点启动代理**

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash minimal/proxy/proxy.sh > /tmp/proxy.log 2>&1 &
curl -fsS http://127.0.0.1:8000/healthcheck
```

5. **发基线请求**

```bash
curl -sS http://127.0.0.1:8000/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "dsv4",
        "prompt": "1+1=",
        "max_tokens": 64
      }' > pre.json
```

6. **触发 P 端异构**

```bash
# 方式一：P 节点直连 executor
bash minimal/trigger/trigger_prefill_direct.sh

# 方式二：任意节点经决策中心
bash minimal/trigger/trigger_prefill_dc.sh
```

7. **等待重启完成**，观察 P 日志出现：

```bash
grep -R "Full-restart barrier passed" /tmp/prefill.log
grep -R "KV connector metadata updated" /tmp/prefill.log
```

8. **发复测请求并对比**

```bash
curl -sS http://127.0.0.1:8000/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "dsv4",
        "prompt": "1+1=",
        "max_tokens": 64
      }' > post.json

# 建议只比较生成文本，JSON 元数据可能有动态字段
python3 - <<'PY'
import json
pre = json.load(open("pre.json"))
post = json.load(open("post.json"))
print("PASS" if pre["choices"][0]["text"] == post["choices"][0]["text"] else "FAIL")
print(pre["choices"][0]["text"][:50])
print(post["choices"][0]["text"][:50])
PY
```

## 可选的 D 端故障/恢复

- D 缩容：`DP16TP1 -> DP15TP1`

```bash
# D 节点直连
bash minimal/trigger/trigger_decode_direct.sh

# 或任意节点经决策中心
bash minimal/trigger/trigger_decode_dc.sh
```

- 恢复：P/D 任一侧或两侧

```bash
# 默认恢复两侧；可加 RECOVER_TARGET=prefill|decode
bash minimal/trigger/trigger_recover_dc.sh
```

D 端故障后若继续走代理发请求，需先把故障 decoder 从代理摘除：

```bash
curl -sS -X POST http://127.0.0.1:8000/instances/remove \
  -H 'Content-Type: application/json' \
  -d '{
        "type": "decode",
        "instances": "<D节点IP>:9115"
      }'
```

恢复后如需重新加入：

```bash
curl -sS -X POST http://127.0.0.1:8000/instances/add \
  -H 'Content-Type: application/json' \
  -d '{
        "type": "decode",
        "instances": "<D节点IP>:9115"
      }'
```

## 注意点

- 这套 minimal 只做“启动 + 触发 + 手动验证”，**没有**自动等待、预热、代理摘除/加回、输出对比等完整场景编排。
- `trigger_*_direct.sh` 必须在对应节点本机执行，因为直连的是本机 ITS executor 端口。
- `trigger_*_dc.sh` 依赖决策中心可用，默认故障 NPU 为：P=`3`，D=`15`。
- P 和 D 模型加载都很慢，建议两端同时启动，等 `/health` 通过后再发请求。
- 直接删掉了完整场景脚本和 `install_vllm_plugins.sh`；新节点从零部署 vllm_plugins 时需另备安装脚本。
- 当前 `.py` / `.sh` 不依赖仓库其它目录，保留 `minimal/decode`、`minimal/prefill`、`minimal/proxy`、`minimal/trigger` 四个子目录即可。
