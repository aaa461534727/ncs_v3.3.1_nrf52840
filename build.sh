#!/usr/bin/env bash
#=============================================================================
# build.sh — NCS v3.3.1 统一构建脚本（唯一构建入口）
#
# 用法:
#   ./build.sh              交互模式
#   ./build.sh list         列出应用
#   ./build.sh new <name>   创建新应用
#   ./build.sh <app>        编译 (sysbuild 模式, 带 MCUboot)
#   ./build.sh <app> flash       编译+烧写 merged.hex
#   ./build.sh <app> clean       清理
#   ./build.sh <app> patches     列出 patch
#   ./build.sh <app> patch-status
#   ./build.sh <app> patch-revert
#
# Patch 机制：
#   apps/<app>/patches/ 下的 .patch 文件会在编译前自动 apply 到 SDK
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SDK 路径: 环境变量 > 自动检测 > 默认路径
if [ -n "${RID_SDK_PATH:-}" ]; then
    SDK_DIR="$RID_SDK_PATH"
elif [ -d "${SCRIPT_DIR}/../v3.3.1/.west" ]; then
    # 自动检测: ncs/v3.3.1-apps 同级默认有 ncs/v3.3.1
    SDK_DIR="$(cd "${SCRIPT_DIR}/../v3.3.1" && pwd)"
elif [ -d "${HOME}/linux/rid/ncs/v3.3.1/.west" ]; then
    SDK_DIR="${HOME}/linux/rid/ncs/v3.3.1"
else
    SDK_DIR=""
fi

if [ -z "$SDK_DIR" ] || [ ! -d "$SDK_DIR/.west" ]; then
    cat >&2 <<'SETUP'
╔══════════════════════════════════════════════════════╗
║  SDK 未找到！                                       ║
║                                                      ║
║  下载并解压 NCS v3.3.1:                              ║
║    cd ~/linux/rid                                     ║
║    wget https://.../ncs-v3.3.1.tar.gz                 ║
║    tar -xzf ncs-v3.3.1.tar.gz                         ║
║                                                      ║
║  或者设置环境变量:                                    ║
║    export RID_SDK_PATH=/your/ncs/v3.3.1/path          ║
║                                                      ║
║  默认路径:                                            ║
║    ${SCRIPT_DIR}/../v3.3.1     (与 v3.3.1-apps 同级) ║
║    ~/linux/rid/ncs/v3.3.1      (主人默认路径)          ║
╚══════════════════════════════════════════════════════╝
SETUP
    exit 1
fi
BOARD="${BOARD:-nrf52840dk/nrf52840}"

export ZEPHYR_BASE="${SDK_DIR}/zephyr"
export ZEPHYR_TOOLCHAIN_VARIANT="gnuarmemb"
export GNUARMEMB_TOOLCHAIN_PATH="/usr"

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

list_apps() {
    for d in "${SCRIPT_DIR}/apps"/*/; do
        [ -f "${d}CMakeLists.txt" ] && basename "$d"
    done
}

find_app() {
    local d="${SCRIPT_DIR}/apps/$1"
    [ -f "${d}/CMakeLists.txt" ] && echo "$d" && return 0
    return 1
}

# =============================================================================
# Patch 管理
# =============================================================================

do_patch_list() {
    local dir="$1"
    local pdir="${dir}/patches"
    if [ ! -d "$pdir" ] || [ -z "$(ls "$pdir"/*.patch 2>/dev/null)" ]; then
        info "无 patch (${pdir}/)"
        return 0
    fi
    echo "Patches (${pdir}/):"
    for p in "$pdir"/*.patch; do
        echo "  $(basename "$p")"
    done
}

do_patch_apply() {
    local name="$1" dir="$2"
    local pdir="${dir}/patches"

    if [ ! -d "$pdir" ] || [ -z "$(ls "$pdir"/*.patch 2>/dev/null)" ]; then
        return 0
    fi

    local applied_flag="${SCRIPT_DIR}/build/${name}/.patches_applied"
    if [ -f "$applied_flag" ]; then
        info "patch 已应用，跳过"
        return 0
    fi

    info "应用 patch 到 SDK (${SDK_DIR})..."
    for p in "$pdir"/*.patch; do
        local pname=$(basename "$p")
        echo "  → ${pname}"
        if patch --batch -p1 -d "${SDK_DIR}" -N -r /dev/null < "$p" 2>&1; then
            ok "    ${pname}"
        else
            local rc=$?
            if [ $rc -eq 1 ]; then
                info "    ${pname} (已打过了, 跳过)"
            else
                die "patch ${pname} 失败! (exit=$rc)"
            fi
        fi
    done
    mkdir -p "$(dirname "$applied_flag")"
    touch "$applied_flag"
    ok "patch 应用完成"
}

do_patch_revert() {
    local name="$1" dir="$2"
    local pdir="${dir}/patches"

    if [ ! -d "$pdir" ] || [ -z "$(ls "$pdir"/*.patch 2>/dev/null)" ]; then
        return 0
    fi

    local applied_flag="${SCRIPT_DIR}/build/${name}/.patches_applied"
    if [ ! -f "$applied_flag" ]; then
        return 0
    fi

    info "回退 patch (SDK: ${SDK_DIR})..."
    for p in $(ls -r "$pdir"/*.patch); do
        local pname=$(basename "$p")
        echo "  ← ${pname}"
        if patch --batch -p1 -d "${SDK_DIR}" -R -r /dev/null < "$p" 2>&1; then
            ok "    ${pname}"
        else
            warn "    回退 ${pname} 失败 (可能已被覆盖), 继续..."
        fi
    done
    rm -f "$applied_flag"
    ok "patch 回退完成"
}

do_patch_status() {
    local name="$1" dir="$2"
    local applied_flag="${SCRIPT_DIR}/build/${name}/.patches_applied"
    if [ -f "$applied_flag" ]; then
        ok "Patches: 已应用"
    else
        info "Patches: 未应用"
    fi
    do_patch_list "$dir"
}

# =============================================================================
# 烧写工具检测 (fallback: nrfjprog → JLinkExe → pyOCD)
# =============================================================================

find_flash_tool() {
    if command -v nrfjprog &>/dev/null; then echo "nrfjprog"; return 0; fi
    if command -v JLinkExe &>/dev/null; then echo "jlink"; return 0; fi
    if command -v pyocd &>/dev/null; then echo "pyocd"; return 0; fi
    echo ""
}

flash_hex() {
    local hex="$1"
    local tool
    tool="$(find_flash_tool)"
    if [ -z "$tool" ]; then
        die "没有烧写工具! 安装: pip install pyocd"
    fi

    case "$tool" in
        nrfjprog)
            info "使用 nrfjprog 烧写..."
            nrfjprog --program "$hex" --sectorerase -f nrf52 || die "nrfjprog 烧写失败"
            nrfjprog --pinresetenable -f nrf52
            nrfjprog --reset -f nrf52
            ;;
        jlink)
            info "使用 JLinkExe 烧写..."
            local script
            script=$(mktemp /tmp/jlink-flash.XXXXXX.jlink)
            cat > "$script" <<JLINK
device nRF52840_xxAA
si SWD
speed 4000
loadfile $hex
r
g
exit
JLINK
            JLinkExe -NoGui 1 -CommandFile "$script" || die "JLinkExe 烧写失败"
            rm -f "$script"
            ;;
        pyocd)
            info "使用 pyOCD 烧写..."
            pyocd flash -t nrf52840 "$hex" || die "pyOCD 烧写失败"
            ;;
    esac
    ok "烧写完成 ($tool)"
}

# =============================================================================
# 构建 (sysbuild 模式: west build --sysbuild → MCUboot + app)
# =============================================================================

has_sysbuild() {
    local app_dir="$1"
    [ -f "${app_dir}/sysbuild/CMakeLists.txt" ] || [ -f "${app_dir}/sysbuild.conf" ]
}

do_build() {
    local name="$1" dir="$2"
    local bdir="${SCRIPT_DIR}/build/${name}"
    local use_sysbuild

    do_patch_apply "$name" "$dir"

    if has_sysbuild "$dir"; then
        use_sysbuild=1
    else
        use_sysbuild=0
    fi

    # 检测构建模式是否变化 (sysbuild ↔ 单应用)
    if [ -f "${bdir}/build_info.yml" ]; then
        local old_mode
        old_mode=$(grep -c sysbuild "${bdir}/build_info.yml" 2>/dev/null || true)
        if [ "$use_sysbuild" = "1" ] && [ "$old_mode" = "0" ]; then
            warn "构建模式变化 (单应用→sysbuild), 清理缓存"
            rm -rf "$bdir"
        elif [ "$use_sysbuild" = "0" ] && [ "$old_mode" != "0" ]; then
            warn "构建模式变化 (sysbuild→单应用), 清理缓存"
            rm -rf "$bdir"
        fi
    fi

    mkdir -p "$bdir"

    # overlay
    local overlay_opt=""
    local ovf="${dir}/boards/${BOARD//\//_}.overlay"
    if [ -f "$ovf" ]; then
        overlay_opt="-DDTC_OVERLAY_FILE=${ovf}"
        info "overlay: $ovf"
    fi

    if [ "$use_sysbuild" = "1" ]; then
        info "模式: sysbuild (MCUboot + $name)"
        info "SDK: $SDK_DIR"
        cd "${SDK_DIR}/zephyr"
        west build --sysbuild -b "$BOARD" "$dir" -d "$bdir" -- $overlay_opt || die "编译失败"
    else
        info "模式: 单应用 (仅 $name)"
        cd "$bdir"
        cmake -GNinja -DBOARD="$BOARD" -DZEPHYR_BASE="$ZEPHYR_BASE" $overlay_opt "$dir" || die "CMake 配置失败"
        ninja || die "编译失败"
    fi

    ok "编译成功: $name"

    # 编译完成后自动 revert patch
    do_patch_revert "$name" "$dir"
    local merged="${bdir}/merged.hex"
    if [ -f "$merged" ]; then
        echo "  烧写: $merged ($(du -h "$merged" | cut -f1))"
        echo "  烧写命令: ./build.sh $name flash"
    fi
    local zip="${bdir}/dfu_application.zip"
    if [ -f "$zip" ]; then
        echo "  OTA: $zip ($(du -h "$zip" | cut -f1))"
    fi
    # flash usage
    local zmap
    zmap=$(find "$bdir" -name "zephyr.map" -path "*/${name}/*" 2>/dev/null | head -1)
    [ -z "$zmap" ] && zmap=$(find "$bdir" -name "zephyr.map" 2>/dev/null | head -1)
    if [ -n "$zmap" ]; then
        grep -A3 "Memory region" "$zmap" 2>/dev/null || true
    fi
}

do_flash() {
    local name="$1"
    local bdir="${SCRIPT_DIR}/build/${name}"
    local merged="${bdir}/merged.hex"

    if [ ! -f "$merged" ]; then
        die "merged.hex 不存在，请先编译: ./build.sh $name"
    fi

    info "烧写 merged.hex (MCUboot + $name)"
    info "目标: $merged"
    flash_hex "$merged"
}

do_clean() {
    local name="$1" dir="$2"
    do_patch_revert "$name" "$dir"
    rm -rf "${SCRIPT_DIR}/build/$1" && ok "清理: $1"
}

do_new() {
    local name="$1" dir="${SCRIPT_DIR}/apps/${name}"
    [ -d "$dir" ] && die "已存在: $name"
    mkdir -p "$dir/src" "$dir/boards" "$dir/sysbuild" "$dir/patches"

    # CMakeLists.txt
    cat > "$dir/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS \$ENV{ZEPHYR_BASE})
project($name)
target_sources(app PRIVATE src/main.c)
CMAKE

    # prj.conf
    cat > "$dir/prj.conf" <<PRJ
CONFIG_LOG=y
CONFIG_PRINTK=y
PRJ

    # main.c
    cat > "$dir/src/main.c" <<MAIN
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
LOG_MODULE_REGISTER($name, LOG_LEVEL_INF);
int main(void) {
    LOG_INF("$name started on %s", CONFIG_BOARD);
    return 0;
}
MAIN

    # sysbuild (MCUboot)
    cat > "$dir/sysbuild/CMakeLists.txt" <<SYSB
find_package(Sysbuild REQUIRED HINTS \$ENV{ZEPHYR_BASE})
project(sysbuild LANGUAGES)
SYSB
    echo 'SB_CONFIG_BOOTLOADER_MCUBOOT=y' > "$dir/sysbuild.conf"

    # patches README
    cat > "$dir/patches/README.md" <<'PATCHMD'
# SDK Patches

补丁文件放在这里，命名规则: `NNNN-简短描述.patch`

制作 patch:
  cd ~/linux/rid/ncs/v3.3.1
  cp path/to/file.c /tmp/file.c.orig
  vim path/to/file.c                              # 改代码
  diff -u /tmp/file.c.orig path/to/file.c > /tmp/raw.patch
  sed -i 's|--- /tmp/.*|--- a/path/to/file.c|' /tmp/raw.patch
  sed -i 's|+++ path/.*|+++ b/path/to/file.c|' /tmp/raw.patch
  cp /tmp/file.c.orig path/to/file.c              # 恢复 SDK
  cp /tmp/raw.patch apps/<app>/patches/0001-描述.patch

build.sh 会在编译前自动 apply，clean 时自动 revert。
PATCHMD

    ok "已创建 $name"
    echo "  编辑: vim ${dir}/src/main.c"
    echo "  编译: ./build.sh $name"
    echo "  烧写: ./build.sh $name flash"
}

help() {
    cat <<HELP
用法: ./build.sh [应用] [命令]

list              列出应用
new <name>        创建新应用
setup             检查环境依赖
<app>             编译 (sysbuild 模式, 带 MCUboot)
<app> flash       编译+烧写 merged.hex
<app> flash-only  仅烧写 (不编译)
<app> clean       清理 (自动 revert patch)
<app> patches     列出 patch
<app> patch-status 查看 patch 状态
<app> patch-revert 回退所有 patch

SDK 路径: 默认检测 ../v3.3.1 或 ~/linux/rid/ncs/v3.3.1
         设置: export RID_SDK_PATH=/your/path
应用目录: apps/<name>/
HELP
}

do_setup() {
    echo "=== 环境检查 ==="
    echo ""

    local ok=0
    check_cmd() {
        if command -v "$1" &>/dev/null; then
            echo "  ✅ $1"
        else
            echo "  ❌ $1 — 请安装"
            ok=1
        fi
    }

    echo "SDK: $SDK_DIR"
    if [ -d "$SDK_DIR/.west" ]; then
        echo "  ✅ SDK 就绪"
    else
        echo "  ❌ SDK 无效 (缺少 .west/)"
        ok=1
    fi

    echo ""
    echo "编译工具:"
    check_cmd cmake
    check_cmd ninja
    check_cmd west
    check_cmd arm-none-eabi-gcc
    check_cmd python3
    check_cmd fzf

    echo ""
    echo "烧写工具 (至少需要一个):"
    if command -v nrfjprog &>/dev/null; then
        echo "  ✅ nrfjprog"
    elif command -v JLinkExe &>/dev/null; then
        echo "  ✅ JLinkExe"
    elif command -v pyocd &>/dev/null; then
        echo "  ✅ pyOCD"
    else
        echo "  ❌ 没有任何烧写工具! 请安装 nrf-command-line-tools 或 pip install pyocd"
        ok=1
    fi

    echo ""
    if [ $ok -eq 0 ]; then
        echo "✅ 环境全部就绪"
    else
        echo "⚠️  有缺失项，请按提示修复"
    fi
}

main() {
    case "${1:-}" in
        ""|interactive)
            local apps=($(list_apps))
            [ ${#apps[@]} -eq 0 ] && die "没有应用 (试试 ./build.sh new <name>)"
            # fzf 菜单选择
            local menu_opts=("${apps[@]}" "[新建应用]" "[退出]")
            local choice
            choice=$(printf '%s\n' "${menu_opts[@]}" | fzf --prompt="选择应用: " --height=10 --layout=reverse)
            case "$choice" in
                "[新建应用]")
                    read -r -p "名字: "
                    [ -n "$REPLY" ] && do_new "$REPLY"
                    return ;;
                "[退出]"|"") return ;;
                *) app="$choice" ;;
            esac
            local action
            action=$(printf '编译\n仅烧写\n编译+烧写\n清理' | fzf --prompt="选择操作: " --height=10 --layout=reverse)
            case "$action" in
                编译)    do_build "$app" "$(find_app "$app")" ;;
                仅烧写)  do_flash "$app" ;;
                编译+烧写) do_build "$app" "$(find_app "$app")" && do_flash "$app" ;;
                清理)    do_clean "$app" "$(find_app "$app")" ;;
            esac
            ;;
        list) list_apps ;;
        new)  [ $# -ge 2 ] || die "用法: ./build.sh new <name>"; do_new "$2" ;;
        setup)        do_setup ;;
        -h|--help|help) help ;;
        *)
            local app="$1" dir; shift
            dir="$(find_app "$app")" || die "不存在: $app"
            case "${1:-build}" in
                build|"")     do_build "$app" "$dir" ;;
                flash)        do_build "$app" "$dir" && do_flash "$app" ;;
                flash-only)   do_flash "$app" ;;
                clean)        do_clean "$app" "$dir" ;;
                patches)      do_patch_list "$dir" ;;
                patch-status) do_patch_status "$app" "$dir" ;;
                patch-revert) do_patch_revert "$app" "$dir" ;;
                *)            die "未知: $1" ;;
            esac
            ;;
    esac
}

main "$@"
