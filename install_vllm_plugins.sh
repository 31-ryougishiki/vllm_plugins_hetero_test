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
#   VLLM_ITS_DEEPSEEK_V4 1=安装 DeepSeek-V4 patch 族（默认 1；
#                        本测试目录只调试 DeepSeek-V4 场景，必须与运行期一致）
#
# 依赖：远程节点已安装并可直接 import vllm / vllm_ascend。

set -euo pipefail

WORK_ROOT="${WORK_ROOT:-/opt/its/z30055003}"
VLLM_PLUGINS_REPO="${VLLM_PLUGINS_REPO:-${WORK_ROOT}/vllm_plugins}"

# 合并后的 vllm_plugins 默认走 0829 实现；DeepSeek-V4 场景必须在
# setup.py 执行期就选择 deepseekv4/ 源目录，否则整文件替换会装上 0829 版本。
VLLM_ITS_DEEPSEEK_V4="${VLLM_ITS_DEEPSEEK_V4:-1}"
export VLLM_ITS_DEEPSEEK_V4
PATCH_FAMILY=0829-default
case "${VLLM_ITS_DEEPSEEK_V4}" in
    1|true|yes|on) PATCH_FAMILY=DeepSeek-V4 ;;
esac

echo "============================================================"
echo "[install] work root        : ${WORK_ROOT}"
echo "[install] vllm_plugins repo: ${VLLM_PLUGINS_REPO}"
echo "[install] patch family     : ${PATCH_FAMILY}"
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
python3 - <<'PY'
import sys

import vllm
import vllm_ascend  # noqa: F401
from packaging.version import Version

print(f"[install] python executable : {sys.executable}")
print(f"[install] vllm version        : {vllm.__version__}")
print(f"[install] vllm file            : {vllm.__file__}")
print(f"[install] vllm_ascend file    : {vllm_ascend.__file__}")

if vllm.__version__ != "dev":
    if Version(vllm.__version__) < Version("0.23.0"):
        print(
            "[ERROR] DeepSeek-V4 heterogeneous restart requires "
            "vllm>=0.23.0. The current python3 environment has "
            f"vllm {vllm.__version__}. Install vllm_plugins with the "
            "SAME python used by the v0.23.0 'vllm serve' command.",
            file=sys.stderr,
        )
        sys.exit(1)
PY

cd "${VLLM_PLUGINS_REPO}"

# 与 vllm_plugins/build.sh 保持一致：离线构建 wheel 并安装。
# setup.py 会执行已配置的运行时源码替换，并备份原文件为 *.bak。
export PIP_NO_INDEX=1

echo "[install] building vllm_plugins wheel ..."
python3 -m pip wheel --verbose --no-deps --no-build-isolation . -w dist/

echo "[install] installing vllm_plugins wheel ..."
# 匹配仓库 setup.py 定义的包名 hw-modelmate-vllm-custom-plugins。
WHEEL="$(ls -1 dist/hw_modelmate_vllm_custom_plugins-*.whl 2>/dev/null | head -n 1)"
if [[ -z "${WHEEL}" ]]; then
    WHEEL="$(ls -1 dist/hw-modelmate-vllm-custom-plugins-*.whl 2>/dev/null | head -n 1)"
fi
if [[ -z "${WHEEL}" ]]; then
    echo "[ERROR] built wheel not found in ${VLLM_PLUGINS_REPO}/dist" >&2
    exit 1
fi
python3 -m pip install --no-deps --force-reinstall "${WHEEL}"

# 校验插件包和入口点。
python3 - <<'PY'
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

# 校验 setup.py 实际替换的是 DeepSeek-V4（deepseekv4/）整文件版本。
# 若这里失败，说明 VLLM_ITS_DEEPSEEK_V4 没有在 pip wheel 时被继承。
python3 - <<'PY'
import vllm.config.parallel as vp

assert hasattr(vp.ParallelConfig, "is_heterogeneous_tp"), (
    "vllm/config/parallel.py lacks DeepSeek-V4 HeterogeneousDPConfig support; "
    "setup.py may have installed the 0829 default replacement."
)
assert hasattr(vp.ParallelConfig, "get_tp_size_for_dp"), (
    "vllm/config/parallel.py lacks get_tp_size_for_dp."
)

import vllm_custom_plugins.plugins.zero_interrupt.deepseekv4.patch as dsv4_patch
assert hasattr(dsv4_patch, "apply"), "deepseekv4 patch module not packaged"

print("[install] DeepSeek-V4 whole-file replacement verified")
PY

echo "[install] done."
echo "[install] remember to export VLLM_CUSTOM_PATCHES=zero_interrupt and"
echo "[install] VLLM_ITS_DEEPSEEK_V4=${VLLM_ITS_DEEPSEEK_V4} when launching service."
