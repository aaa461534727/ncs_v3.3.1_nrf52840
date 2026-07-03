#!/usr/bin/env bash
#=============================================================================
# build.sh — NCS v3.3.1 统一构建脚本
#
# 用法:
#   ./build.sh              交互模式
#   ./build.sh list         列出应用
#   ./build.sh new <name>   创建新应用
#   ./build.sh <app>        编译
#   ./build.sh <app> flash  编译+烧写
#   ./build.sh <app> clean  清理
#
# Patch 机制：
#   apps/<app>/patches/ 下的 .patch 文件会在 cmake 前自动 apply 到 SDK
#   用 ./build.sh <app> patch-status 查看当前已应用的 patch
#   用 ./build.sh <app> patch-revert 回退所有 patch
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="/home/dengbaowen/linux/rid/ncs/v3.3.1"
BOARD="${BOARD:-nrf52840dk/nrf52840}"

export ZEPHYR_BASE="${SDK_DIR}/zephyr"
export ZEPHYR_TOOLCHAIN_VARIANT="gnuarmemb"
export GNUARMEMB_TOOLCHAIN_PATH="/usr"

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
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
PATCH_DIR_VAR_NAME="PATCHES_APPLIED_${BOARD//\//_}"

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
        return 0  # 无 patch 不是错
    fi

    # 检查是否已 apply (标记文件在 build 目录下)
    local applied_flag="${SCRIPT_DIR}/build/${name}/.patches_applied"
    if [ -f "$applied_flag" ]; then
        info "patch 已应用，跳过"
        return 0
    fi

    info "应用 patch 到 SDK (${SDK_DIR})..."
    local errors=0
    for p in "$pdir"/*.patch; do
        local pname=$(basename "$p")
        echo "  → ${pname}"
        if patch -p0 -d "${SDK_DIR}" -N -r /dev/null < "$p" 2>&1; then
            ok "    ${pname}"
        else
            local rc=$?
            # patch -N 返回 1 = 已经打过 (跳过), 不是错误
            if [ $rc -eq 1 ]; then
                info "    ${pname} (已打过了, 跳过)"
            else
                die "patch ${pname} 失败! (exit=$rc), 请检查 SDK 是否干净"
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
        info "无 patch 可回退"
        return 0
    fi

    local applied_flag="${SCRIPT_DIR}/build/${name}/.patches_applied"
    if [ ! -f "$applied_flag" ]; then
        info "patch 未应用，无需回退"
        return 0
    fi

    info "回退 patch (SDK: ${SDK_DIR})..."
    # 倒序回退
    for p in $(ls -r "$pdir"/*.patch); do
        local pname=$(basename "$p")
        echo "  ← ${pname}"
        if patch -p0 -d "${SDK_DIR}" -R -r /dev/null < "$p" 2>&1; then
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

do_cmake() {
    local name="$1" dir="$2" bdir
    bdir="${SCRIPT_DIR}/build/${name}"
    mkdir -p "$bdir"
    cd "$bdir"
    local overlay=""
    local ovf="${dir}/boards/${BOARD//\//_}.overlay"
    [ -f "$ovf" ] && overlay="-DDTC_OVERLAY_FILE=${ovf}" && info "overlay: $ovf"
    cmake -GNinja -DBOARD="$BOARD" -DZEPHYR_BASE="$ZEPHYR_BASE" $overlay "$dir"
    ok "配置: $name"
}

do_build() {
    local name="$1" dir="$2" bdir
    bdir="${SCRIPT_DIR}/build/${name}"
    do_patch_apply "$name" "$dir"
    [ -f "${bdir}/CMakeCache.txt" ] || do_cmake "$name" "$dir"
    cd "$bdir" && ninja
    ok "编译成功: $name"
    local b="${bdir}/zephyr/zephyr.bin"
    [ -f "$b" ] && echo "  bin: $b ($(du -h "$b" | cut -f1))"
    grep -A3 "Memory region" "${bdir}/zephyr/zephyr.map" 2>/dev/null
}

do_flash() {
    local name="$1" bdir
    bdir="${SCRIPT_DIR}/build/${name}"
    [ -f "${bdir}/CMakeCache.txt" ] || die "先编译: ./build.sh $name"
    cd "$bdir" && west flash --runner jlink
    ok "烧写: $name"
}

do_clean() {
    local name="$1" dir="$2"
    do_patch_revert "$name" "$dir"
    rm -rf "${SCRIPT_DIR}/build/$1" && ok "清理: $1"
}

do_menuconfig() {
    local name="$1" dir="$2" bdir
    bdir="${SCRIPT_DIR}/build/${name}"
    do_patch_apply "$name" "$dir"
    [ -f "${bdir}/CMakeCache.txt" ] || do_cmake "$name" "$dir"
    cd "$bdir" && west build -t menuconfig
}

do_new() {
    local name="$1" dir="${SCRIPT_DIR}/apps/${name}"
    [ -d "$dir" ] && die "已存在: $name"
    mkdir -p "$dir/src" "$dir/boards" "$dir/patches"
    # patches README
    cat > "$dir/patches/README.md" <<'PATCHMD'
# SDK Patches

补丁文件放在这里，命名规则: `NNNN-简短描述.patch`

例如: `0001-uart-mcumgr-debug-log.patch`

## 创建补丁

```bash
cd /home/dengbaowen/linux/rid/ncs/v3.3.1
git diff > /home/dengbaowen/linux/rid/ncs/v3.3.1-apps/apps/rid0/patches/0001-xxx.patch
```

如果在非 git 管理的 SDK 上修改了文件：

```bash
cd /home/dengbaowen/linux/rid/ncs/v3.3.1
diff -ruN . ~/ncs-orig-backup/ > patches/0001-xxx.patch
```

## 注意事项

- patch 文件路径相对于 SDK 根目录 (`ncs/v3.3.1/`)
- 按编号排序 apply，倒序 revert
- `build.sh` 会自动在 cmake 前 apply，clean 时 revert
PATCHMD
    cat > "$dir/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS \$ENV{ZEPHYR_BASE})
project($name)
target_sources(app PRIVATE src/main.c)
CMAKE
    cat > "$dir/prj.conf" <<PRJ
CONFIG_LOG=y
CONFIG_PRINTK=y
PRJ
    cat > "$dir/src/main.c" <<MAIN
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
LOG_MODULE_REGISTER($name, LOG_LEVEL_INF);
int main(void) {
    LOG_INF("$name started on %s", CONFIG_BOARD);
    return 0;
}
MAIN
    ok "已创建 $name (vim ${dir}/src/main.c)"
}

help() {
    cat <<HELP
用法: ./build.sh [应用] [命令]

list              列出应用
new <name>        创建新应用
<app>             编译
<app> flash       编译+烧写
<app> clean       清理
<app> patches     列出 patch
<app> patch-status 查看 patch 状态
<app> patch-revert 回退所有 patch

应用目录: apps/<name>/
HELP
}

main() {
    case "${1:-}" in
        ""|interactive)
            local apps=($(list_apps))
            [ ${#apps[@]} -eq 0 ] && die "没有应用 (试试 ./build.sh new <name>)"
            echo "应用:"; local i
            for i in "${!apps[@]}"; do echo "  [$((i+1))] ${apps[$i]}"; done
            echo "  [n] 新应用"
            read -r -p "选择 (1-${#apps[@]}/n): " s
            case "$s" in
                n|N) read -r -p "名字: "; [ -n "$REPLY" ] && do_new "$REPLY"; exit ;;
                *) local idx=$((s-1)); app="${apps[$idx]}" ;;
            esac
            echo "1)编译 2)编译+烧写 3)清理"
            read -r -p "选择: " c
            case "$c" in
                1) do_build "$app" "$(find_app "$app")" ;;
                2) do_build "$app" "$(find_app "$app")" && do_flash "$app" ;;
                3) do_clean "$app" "$(find_app "$app")" ;;
            esac
            ;;
        list) list_apps ;;
        new)  [ $# -ge 2 ] || die "用法: ./build.sh new <name>"; do_new "$2" ;;
        -h|--help|help) help ;;
        *)
            local app="$1" dir; shift
            dir="$(find_app "$app")" || die "不存在: $app"
            case "${1:-build}" in
                build|"")     do_build "$app" "$dir" ;;
                flash)        do_build "$app" "$dir" && do_flash "$app" ;;
                clean)        do_clean "$app" "$dir" ;;
                menuconfig)   do_menuconfig "$app" "$dir" ;;
                patches)      do_patch_list "$dir" ;;
                patch-status) do_patch_status "$app" "$dir" ;;
                patch-revert) do_patch_revert "$app" "$dir" ;;
                *)            die "未知: $1" ;;
            esac
            ;;
    esac
}

main "$@"
