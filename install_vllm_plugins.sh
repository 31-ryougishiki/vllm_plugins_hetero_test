#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Copyright (c) Huawei Technologies Co., Ltd. 2026-2026. All rights reserved.
#
# 安装 vllm_plugins 仓
#
# 使用方式：
#   bash install_vllm_plugins.sh
#
# 环境变量：
#   WORK_ROOT            远程工作路径，默认 /opt/its/z30055003
#   VLLM_PLUGINS_REPO    vllm_plugins 仓路径，默认 ${WORK_ROOT}/vllm_plugins
#   VLLM_ITS_DEEPSEEK_V4 运行期 patch 族开关；安装阶段已不再依赖，
#                        本目录 launch 脚本默认运行期使用 1
#
# 依赖：远程节点已安装并可直接 import vllm / vllm_ascend。

set -euo pipefail

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
VLLM_PLUGINS_REPO="${VLLM_PLUGINS_REPO:-${WORK_ROOT}/vllm_plugins}"
# 与 launch 脚本保持一致：安装/校验/启动必须使用同一个解释器，
# 否则 wheel 装进一个环境、launch 用另一个环境，patch 不会生效。
PYTHON_BIN="${PYTHON_BIN:-python3}"

# setup.py 现在安装统一替换文件，安装结果与 VLLM_ITS_DEEPSEEK_V4 无关。
# 这里保留导出只是为了把“运行期应使用 1”的约定传给后续校验输出。
VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"
export VLLM_ITS_DEEPSEEK_V4

echo "============================================================"
echo "[install] work root        : ${WORK_ROOT}"
echo "[install] vllm_plugins repo: ${VLLM_PLUGINS_REPO}"
echo "[install] python           : ${PYTHON_BIN} -> $(command -v "${PYTHON_BIN}")"
echo "[install] replacement      : unified (runtime dispatch)"
echo "[install] runtime flag     : VLLM_ITS_DEEPSEEK_V4=${VLLM_ITS_DEEPSEEK_V4}"
echo "============================================================"

if [[ ! -d "${VLLM_PLUGINS_REPO}" ]]; then
    echo "[ERROR] vllm_plugins repo not found: ${VLLM_PLUGINS_REPO}" >&2
    echo "        please upload repo first, or set VLLM_PLUGINS_REPO" >&2
    exit 1
fi

if [[ ! -f "${VLLM_PLUGINS_REPO}/build.sh" ]]; then
    echo "[ERROR] build.sh not found in ${VLLM_PLUGINS_REPO}" >&2
    exit 1
fi

# 安装前确认 vllm / vllm_ascend 可用，并且是 DeepSeek-V4 所需的 v0.23.0。
"${PYTHON_BIN}" - <<'PY'
import sys

import vllm
import vllm_ascend  # noqa: F401
from packaging.version import Version

print(f"[install] python executable : {sys.executable}")
print(f"[install] vllm version        : {vllm.__version__}")
print(f"[install] vllm file            : {vllm.__file__}")
print(f"[install] vllm_ascend file    : {vllm_ascend.__file__}")

if vllm.__version__ != "dev":
    if Version(vllm.__version__).base_version < Version("0.23.0").base_version:
        print(
            "[ERROR] DeepSeek-V4 heterogeneous restart requires "
            "vllm>=0.23.0. The current environment has "
            f"vllm {vllm.__version__}. Install vllm_plugins with the "
            "SAME python used by the v0.23.0 'vllm serve' command "
            "(pass PYTHON_BIN=...).",
            file=sys.stderr,
        )
        sys.exit(1)
PY

cd "${VLLM_PLUGINS_REPO}"

# 与 vllm_plugins/build.sh 保持一致：离线构建 wheel 并安装。
# setup.py 会执行已配置的运行时源码替换，并备份原文件为 *.bak。
export PIP_NO_INDEX=1

echo "[install] building vllm_plugins wheel ..."
"${PYTHON_BIN}" -m pip wheel --verbose --no-deps --no-build-isolation . -w dist/

echo "[install] installing vllm_plugins wheel ..."
# 匹配仓库 setup.py 定义的包名 hw-modelmate-vllm-custom-plugins。
# ``set -euo pipefail`` 下 ls 找不到匹配时整个命令替换会直接退出，
# 后面的 fallback/错误提示不会执行，所以这里显式容忍非零退出码。
WHEEL="$(ls -1 dist/hw_modelmate_vllm_custom_plugins-*.whl 2>/dev/null | head -n 1 || true)"
if [[ -z "${WHEEL}" ]]; then
    WHEEL="$(ls -1 dist/hw-modelmate-vllm-custom-plugins-*.whl 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${WHEEL}" ]]; then
    echo "[ERROR] built wheel not found in ${VLLM_PLUGINS_REPO}/dist" >&2
    exit 1
fi
"${PYTHON_BIN}" -m pip install --no-deps --force-reinstall "${WHEEL}"

# 校验插件包和入口点。
"${PYTHON_BIN}" - <<'PY'
import importlib.metadata as md

import vllm_custom_plugins

entry_points = {
    ep.name: ep.value
    for ep in md.entry_points(group="vllm.general_plugins")
    if "vllm_custom_plugins" in ep.value
}
print(f"[install] vllm_custom_plugins : {vllm_custom_plugins.__file__}")
print(f"[install] entry points         : {entry_points}")
assert entry_points, "vllm_custom_plugins entry point not registered"
PY

# 校验 setup.py 安装的统一替换文件同时包含 DeepSeek-V4 与 0829 能力。
"${PYTHON_BIN}" - <<'PY'
import vllm.config.parallel as vp

assert hasattr(vp.ParallelConfig, "is_heterogeneous_tp"), (
    "vllm/config/parallel.py lacks DeepSeek-V4 HeterogeneousDPConfig support; "
    "setup.py may not have installed the unified replacement."
)
assert hasattr(vp.ParallelConfig, "get_tp_size_for_dp"), (
    "vllm/config/parallel.py lacks get_tp_size_for_dp."
)

import vllm_custom_plugins.plugins.zero_interrupt.deepseekv4.patch as dsv4_patch
assert hasattr(dsv4_patch, "apply"), "deepseekv4 patch module not packaged"

print("[install] unified DeepSeek-V4/0829 replacement verified")
PY

# 校验 runtime patch 注册链路真的可用（README 步骤 3）：
# 这里会打印 "VLLM_ITS_DEEPSEEK_V4=1: applying DeepSeek-V4 patch family"
# 以及各个 heterogeneous-TP patch 的 Applied 日志。
VLLM_ITS_DEEPSEEK_V4=1 VLLM_CUSTOM_PATCHES=zero_interrupt \
    "${PYTHON_BIN}" - <<'PY'
from vllm_custom_plugins.plugins.zero_interrupt.patch import apply

apply()
print("zero_interrupt.apply() OK")
PY

# 校验 deepseek_v4 tool parser 已注册（README 步骤 4）：
# api_server 启动时 validate_api_server_args 会拒绝未注册的 parser。
VLLM_ITS_DEEPSEEK_V4=1 VLLM_CUSTOM_PATCHES=zero_interrupt \
    "${PYTHON_BIN}" -c "from vllm.tool_parsers import ToolParserManager as M; assert 'deepseek_v4' in M.list_registered(), M.list_registered(); print('deepseek_v4 tool parser registered:', M.list_registered())"

echo "[install] done."
echo "[install] remember to export VLLM_CUSTOM_PATCHES=zero_interrupt and"
echo "[install] VLLM_ITS_DEEPSEEK_V4=${VLLM_ITS_DEEPSEEK_V4} when launching service."
