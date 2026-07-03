#!/usr/bin/env bash
# =============================================================
# setup.sh — RID NCS 一键环境配置
#
# 用法：sudo ./setup.sh          # 完整安装（需要 sudo 权限）
#       sudo ./setup.sh check   # 仅检测
#       sudo ./setup.sh sdk     # 仅下载 SDK
#       sudo ./setup.sh deps    # 仅安装系统依赖
#
# 依赖：bash, curl, git, python3, pip3, wget
# =============================================================

set -euo pipefail
# 某些命令允许失败（apt update 网络问题等）
APT_ERR_OK=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_DIR="$SCRIPT_DIR/../v3.3.1"
# 支持 RID_SDK_PATH 覆盖
[ -n "${RID_SDK_PATH:-}" ] && SDK_DIR="$RID_SDK_PATH"
SDK_VERSION="v3.3.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo ""; echo -e "${GREEN}▶ $1${NC}"; }

# ---- 检测 ----
check_prereqs() {
    local missing=0

    for c in bash python3 pip3 wget; do
        if ! command -v $c &>/dev/null; then
            log_error "缺少: $c"
            missing=1
        fi
    done

    # 可选
    command -v ninja &>/dev/null || log_warn "未安装 ninja (cmake 会降级)"
    command -v dtc  &>/dev/null || log_warn "未安装 device-tree-compiler"
    command -v gcc-arm-none-eabi &>/dev/null || log_warn "未安装 gcc-arm-none-eabi"

    if [ $missing -ne 0 ]; then
        log_error "请先安装缺失的命令"
        exit 1
    fi
    log_info "基本依赖满足"
}

check_sdk() {
    if [ -d "$SDK_DIR" ] && [ -f "$SDK_DIR/.west/config" ]; then
        local version
        version=$(cat "$SDK_DIR/nrf/VERSION" 2>/dev/null || echo "unknown")
        log_info "SDK 已存在: $SDK_DIR (版本 $version)"
        return 0
    fi
    log_warn "SDK 未安装: $SDK_DIR"
    return 1
}

# ---- 安装系统依赖 ----
install_deps() {
    log_step "安装系统依赖"

    if ! command -v sudo &>/dev/null; then
        log_error "需要 sudo 权限，请以 root 运行或安装 sudo"
        exit 1
    fi

    log_info "更新包索引..."
    sudo apt-get update -qq 2>&1 || log_warn "apt update 有警告，继续..."

    log_info "安装编译工具..."
    sudo apt-get install -y -qq \
        git ninja-build device-tree-compiler \
        python3 python3-pip python3-venv \
        cmake gperf ccache dfu-util \
        file wget curl fzf 2>&1 || log_warn "部分包安装失败，继续..."

    log_info "安装 ARM 工具链..."
    sudo apt-get install -y -qq gcc-arm-none-eabi 2>&1 || {
        log_warn "apt 装 gcc-arm-none-eabi 失败，尝试手动下载..."
        log_info "去 https://developer.arm.com/downloads/-/gnu-rm 下载工具链"
    }

    log_info "安装 Python 依赖..."
    pip3 install \
        west \
        pyelftools \
        pykwalify 2>&1 || log_warn "pip 安装部分包失败"

    log_info "系统依赖安装完成"
}

# ---- 下载 SDK ----
download_sdk() {
    log_step "安装 NCS SDK $SDK_VERSION"

    local sdk_parent
    sdk_parent="$(dirname "$SDK_DIR")"
    mkdir -p "$sdk_parent"

    if [ -d "$SDK_DIR/.west" ]; then
        log_info "SDK 已存在: $SDK_DIR"
        return 0
    fi

    # 用 west.yml 拉取 SDK（git clone + west update）
    log_info "通过 west 初始化 SDK (从 west.yml)..."
    log_info "目标: $SDK_DIR"
    log_info "这需要 git 访问 GitHub/ Nordic，约 4.2GB，可能需要 20-40 分钟"

    cd "$sdk_parent"

    # west init 以 v3.3.1-apps 的 west.yml 为 manifest
    west init -m "$SCRIPT_DIR" --mr master --mf west.yml "$SDK_DIR" 2>&1 || {
        log_error "west init 失败，请检查网络和 git"
        log_error "手动安装: cd $sdk_parent && git clone https://github.com/nrfconnect/sdk-nrf --branch v3.3.1"
        exit 1
    }

    cd "$SDK_DIR"

    log_info "west update (下载所有子仓库)..."
    west update 2>&1 || {
        log_warn "west update 部分失败，可能是网络问题"
        log_info "重试: cd $SDK_DIR && west update"
    }

    log_info "安装 Zephyr Python 依赖..."
    pip3 install -r zephyr/scripts/requirements.txt 2>&1 || log_warn "部分 pip 包安装失败"
    pip3 install -r nrf/scripts/requirements.txt 2>/dev/null || true
    pip3 install -r bootloader/mcuboot/scripts/requirements.txt 2>/dev/null || true

    cd "$SCRIPT_DIR"
    log_info "SDK 安装完成: $SDK_DIR"
}

# ---- 后置检查 ----
post_check() {
    log_step "后置检查"

    if ! check_sdk; then
        log_error "SDK 检查失败"
        exit 1
    fi

    # 验证编译环境
    local sdk="$SDK_DIR"
    log_info "验证 Zephyr 版本..."
    if [ -f "$sdk/zephyr/VERSION" ]; then
        cat "$sdk/zephyr/VERSION"
    fi

    log_info "验证工具链..."
    arm-none-eabi-gcc --version 2>&1 | head -1

    log_info "验证 west..."
    west --version 2>&1 || true

    log_info ""
    log_info "========================================"
    log_info "  ✅ 环境就绪！"
    log_info ""
    log_info "  编译:   cd $SCRIPT_DIR && source env.sh && west build ..."
    log_info "  一键:   ./build.py rid0"
    log_info "========================================"
    log_info ""
}

# ---- 主入口 ----
cmd="${1:-all}"

case "$cmd" in
    check)
        check_prereqs
        check_sdk
        ;;
    deps)
        install_deps
        ;;
    sdk)
        download_sdk
        post_check
        ;;
    all|"")
        log_step "RID NCS v3.3.1 环境一键配置"
        check_prereqs
        if check_sdk; then
            log_info "SDK 已就绪，跳过安装"
            post_check
            exit 0
        fi
        install_deps
        download_sdk
        post_check
        ;;
    *)
        echo "用法: $0 [check|deps|sdk|all]"
        exit 1
        ;;
esac
