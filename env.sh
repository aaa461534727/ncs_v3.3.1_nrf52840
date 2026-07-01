#!/usr/bin/env bash
# =============================================================
# env.sh — RID NCS v3.3.1 环境变量（相对路径、可移植）
#
# 用法：source env.sh
#
# 自动检测 SDK 位置：
#   1. ./../ncs/v3.3.1/  （与 apps 同级）
#   2. <RID_SDK_PATH>     （环境变量覆盖）
#   3. 报错指导安装
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 优先检测 RID_SDK_PATH 环境变量，否则默认 ../ncs/v3.3.1
if [ -n "${RID_SDK_PATH:-}" ]; then
    SDK_DIR="$RID_SDK_PATH"
else
    SDK_DIR="$SCRIPT_DIR/../v3.3.1"
fi

if [ ! -d "$SDK_DIR" ]; then
    echo ""
    echo "========================================================"
    echo "  ❌ NCS SDK 未找到!"
    echo ""
    echo "    SDK 期望路径: $SDK_DIR"
    echo ""
    echo "  请执行以下任一种:"
    echo "    1. 自动下载:  sudo ./setup.sh"
    echo "    2. 环境变量:  export RID_SDK_PATH=/your/sdk/path"
    echo ""
    echo "  SDK 下载链接:"
    echo "    https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-SDK/Download"
    echo "========================================================"
    echo ""
    return 1
fi

export SDK_DIR="$SDK_DIR"
export ZEPHYR_BASE="$SDK_DIR/zephyr"
export ZEPHYR_TOOLCHAIN_VARIANT="gnuarmemb"
export GNUARMEMB_TOOLCHAIN_PATH="/usr"
export APPS_DIR="$SCRIPT_DIR/apps"
export BOARD="${BOARD:-nrf52840dk/nrf52840}"

echo "[env.sh] SDK_DIR       = $SDK_DIR"
echo "[env.sh] ZEPHYR_BASE   = $ZEPHYR_BASE"
echo "[env.sh] APPS_DIR      = $APPS_DIR"
echo "[env.sh] BOARD         = $BOARD"
echo "[env.sh] ✅ NCS v3.3.1 环境已加载"
