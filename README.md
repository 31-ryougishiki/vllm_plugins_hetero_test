# vllm_plugins 异构重启测试脚本

本目录包含三个基础测试脚本和 PD 分离场景脚本：

| 脚本/目录 | 作用 |
|------|------|
| `install_vllm_plugins.sh` | 在远程 A3 节点安装 `vllm_plugins` 仓 |
| `launch_prefill_hetero_test.sh` | 单机拉起 prefill `DP4TP4`（DeepSeek-V4-Flash-w8a8-mtp + MTP + PD kv_producer） |
| `trigger_hetero_restart.sh` | 模拟 NPU 卡故障，向 4 个 executor 手动下发 `DP4TP(3,4,4,4)` 异构策略 |
| `pd_hetero/` | PD 分离场景 1：prefill 转异构、decode `DP16TP1` 不变，详见 `pd_hetero/README.md` |

假设远程工作路径：`/opt/its/z30055003`。

## 目录约定

```text
/opt/its/z30055003/
├── vllm_plugins                    # 上传后的 vllm_plugins 仓
├── vllm_plugins_hetero_test        # 本目录
└── logs/
    └── prefill/
        ├── dp0.log ... dp3.log
```

## 使用步骤

### 0. 赋可执行权限（如需要）

```bash
chmod +x /opt/its/z30055003/vllm_plugins_hetero_test/*.sh
```

### 1. 上传并安装

```bash
# 将本目录和 vllm_plugins 上传到 A3 节点
# 假设仓库位于 /opt/its/z30055003/vllm_plugins
cd /opt/its/z30055003/vllm_plugins_hetero_test
bash install_vllm_plugins.sh
```

> **版本一致性要求**：DeepSeek-V4 异构功能基于 vLLM v0.23.0。
> 安装脚本会检查 `python3` 环境中的 vllm 版本，低于 0.23.0 会直接失败。
> 同时，启动脚本使用 `python3 -m vllm.entrypoints.openai.api_server`，
> 而不是 PATH 中的 `vllm serve`，避免安装和启动落到不同 Python/vLLM 环境。
> 如需用其它解释器，安装和启动时都传 `PYTHON_BIN=/path/to/python`。

默认使用 `PIP_NO_INDEX=1` 离线构建 wheel，并执行
`vllm_plugins/build.sh install`。安装完成后会做一次 import 校验。

#### 安装完成验证

```bash
# 1. wheel 与插件包
pip show hw-modelmate-vllm-custom-plugins

python3 - <<'PY'
import vllm
import vllm_ascend
import vllm_custom_plugins
import importlib.metadata as md

print("vllm           :", vllm.__file__)
print("vllm-ascend    :", vllm_ascend.__file__)
print("custom plugins :", vllm_custom_plugins.__file__)
eps = [
    ep.value
    for ep in md.entry_points(group="vllm.general_plugins")
    if "vllm_custom_plugins" in ep.value
]
print("entry points   :", eps)
assert eps, "vllm_custom_plugins entry point missing"
PY

# 2. setup.py 的源码替换已生效，且存在 .bak 备份
python3 - <<'PY'
from pathlib import Path
import vllm.config.parallel as vp
import vllm.distributed.parallel_state as vps
import vllm.model_executor.layers.fused_moe.config as vmoe
import vllm_ascend.distributed.parallel_state as ap
import vllm_ascend.worker.worker as aw

checks = [
    ("vllm/config/parallel.py", vp, ("HeterogeneousDPConfig", "get_tp_size_for_dp", "is_heterogeneous_tp")),
    ("vllm/distributed/parallel_state.py", vps, ("init_distributed_environment",)),
    ("vllm/model_executor/layers/fused_moe/config.py", vmoe, ("FusedMoEParallelConfig",)),
    ("vllm_ascend/distributed/parallel_state.py", ap, ("init_ascend_model_parallel_asym",)),
    ("vllm_ascend/worker/worker.py", aw, ("NPUWorker",)),
]
for label, mod, attrs in checks:
    path = Path(mod.__file__).resolve()
    if label == "vllm/config/parallel.py":
        attrs_ok = all(hasattr(mod.ParallelConfig, a) for a in attrs)
    else:
        attrs_ok = all(hasattr(mod, a) for a in attrs)
    bak_ok = Path(str(path) + ".bak").exists()
    print(f"{label:58s} attrs={attrs_ok} bak={bak_ok}")
    assert attrs_ok
PY

# 3. 插件 patch 注册 smoke（应打印 Applied ... heterogeneous-TP ...）
VLLM_CUSTOM_PATCHES=zero_interrupt python3 - <<'PY'
from vllm_custom_plugins.plugins.zero_interrupt.patch import apply

apply()
print("zero_interrupt.apply() OK")
PY

# 4. deepseek_v4 tool parser 已注册（否则 api_server 会拒绝启动）
python3 -c "from vllm.tool_parsers import ToolParserManager as M; print('deepseek_v4' in M.list_registered(), M.list_registered())"
```

其中第 2 步打印的每个模块都应显示 `attrs=True`；第 3 步应看到
zero_interrupt 的 patch 日志；第 4 步应打印 `True`。最终以第 2 节拉起
服务并检查 `/health` 和 ITS `/health` 为准。

### 2. 拉起单机 prefill 服务

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test
nohup bash launch_prefill_hetero_test.sh > /opt/its/z30055003/logs/launch.log 2>&1 &
```

脚本会启动 4 个 `vllm serve`（每个 DP rank 一个 engine）：

| DP rank | NPU | vLLM 端口 | ITS 策略端口 |
|---------|-----|-----------|--------------|
| 0       | 0,1,2,3 | 9000 | 8001 |
| 1       | 4,5,6,7 | 9001 | 8005 |
| 2       | 8,9,10,11 | 9002 | 8009 |
| 3       | 12,13,14,15 | 9003 | 8013 |

启动完成后脚本会等待 4 个 engine 的 `/health` 就绪。

> 本脚本只拉起 **P 端（prefill，kv_producer）**。PD 分离测试时，
> D 端（decode，kv_consumer）仍按现有 16 卡 decode 部署在另一节点/池上。
> `kv_connector_extra_config.prefill.dp_size=4,tp_size=4` 描述的是远端
> prefill 池布局，异构重启后由
> `vllm_custom_plugins...patch_hetero_mooncake.py` 按真实 per-DP
> tp_size(3/4/4/4) 完成端口与 rank 映射。
>
> 默认没有决策中心，脚本会把 `VLLM_ITS_DECISION_CENTER_URL` 指向
> `127.0.0.1:1` 并只重试 1 次以加快测试；有决策中心时覆盖该环境变量即可。
>
> 默认 `VLLM_CUSTOM_PLUGINS_SKIP_LICENSE=1`，跳过 license_verify 以便纯功能
> 测试。生产/正式环境必须去掉该变量（或设为 0），并配置
> `LICENSE_PATH`、`CERT_PATH`、`PRODUCT_KEY_PATH`。

### 3. 手动触发异构重启

```bash
cd /opt/its/z30055003/vllm_plugins_hetero_test
bash trigger_hetero_restart.sh
```

脚本默认模拟 **NPU 3 故障**（DP0 的最后一张卡），向 4 个 ITS HTTP 端口
分别下发 `PD_REBUILD` 策略：

```text
DP0: new_tp=3, tp_asymmetric_shardings=[2,1,1]
DP1..DP3: new_tp=4
```

四个 executor 都会执行 `_cleanup_and_restart_workers()`，最终：
- 全局 world_size = 15
- 全局 torch rank：DP0=0/1/2，DP1=3..6，DP2=7..10，DP3=11..14
- DP0 使用 NPU 0/1/2，其余 DP 各使用 4 张 NPU

可通过环境变量调整：

```bash
# 模拟其它卡故障，例如 DP0 的卡 0
FAULT_NPU=0 bash trigger_hetero_restart.sh

# 使用 DEGRADE 策略（非 PD 链路测试）
DEPLOY_TYPE=DEGRADE bash trigger_hetero_restart.sh

# 只测异构拓扑切换、不下发故障卡信息
SIMULATE_FAULT=false bash trigger_hetero_restart.sh
```

> 默认拓扑把故障卡放在 **DP0（NPU 0/1/2/3）**，所以
> `FAULT_NPU` 应取 0~3；故障卡必须属于 NPU 0~3。

## 收尾/排障

```bash
# 停止全部 prefill 进程
pkill -f "vllm serve /opt/its/model/DeepSeek-V4-Flash-w8a8-mtp-self" || true

# 查看 executor 策略日志
grep -R "restarting workers of EVERY DP instance" /opt/its/z30055003/logs/prefill/

# 查看 ITS HTTP 状态
curl http://127.0.0.1:8001/api/v1/executor/status
```
