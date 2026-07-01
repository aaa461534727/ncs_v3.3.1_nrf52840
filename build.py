#!/usr/bin/env python3
"""
build.py — NCS v3.3.1 统一构建脚本（便携版）

用法:
  ./build.py                   交互模式
  ./build.py list              列出应用
  ./build.py new <name>        创建新应用
  ./build.py <app>             编译
  ./build.py <app> flash       编译+烧写
  ./build.py <app> clean       清理
  ./build.py <app> no-boot     编译（不带 MCUboot）
  ./build.py <app> flash-merged 烧写 merged.hex（MCUboot + app一起烧）

添加新应用: ./build.py new myapp
          vim apps/myapp/src/main.c
          ./build.py myapp

环境变量:
  BOARD=nrf52840dk/nrf52840    默认板型，可覆盖
  NO_SYSBUILD=1                强制不带 MCUboot
  RID_SDK_PATH=<path>          指定 SDK 路径（默认 ../ncs/v3.3.1）

产物（sysbuild 模式）:
  build/<app>/merged.hex        ← MCUboot + app 合体 hex（烧写这个）
  build/<app>/dfu_application.zip  ← OTA 升级包
  build/<app>/mcuboot/          ← MCUboot 单独产物
  build/<app>/<app>/            ← 应用单独产物

应用目录: apps/<name>/
"""

import os
import sys
import shutil
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

# ---- SDK 路径检测（不硬编码！） ----
RID_SDK_PATH = os.environ.get("RID_SDK_PATH")
if RID_SDK_PATH:
    SDK_DIR = Path(RID_SDK_PATH).resolve()
else:
    SDK_DIR = (SCRIPT_DIR / "../v3.3.1").resolve()

if not SDK_DIR.exists():
    print(f"\033[31m[ERROR]\033[0m NCS SDK 未找到！")
    print(f"  期望路径: {SDK_DIR}")
    print(f"  请执行:   sudo ./setup.sh")
    print(f"  或设置:   export RID_SDK_PATH=/your/sdk/path")
    sys.exit(1)

if not (SDK_DIR / ".west" / "config").exists():
    print(f"\033[31m[ERROR]\033[0m {SDK_DIR} 不是有效的 NCS SDK（缺少 .west/config）")
    print(f"  请执行:   sudo ./setup.sh")
    sys.exit(1)

# ---- 其他路径 ----
APPS_DIR = SCRIPT_DIR / "apps"
BUILD_DIR = SCRIPT_DIR / "build"
BOARD = os.environ.get("BOARD", "nrf52840dk/nrf52840")

# 环境变量
os.environ["ZEPHYR_BASE"] = str(SDK_DIR / "zephyr")
os.environ["ZEPHYR_TOOLCHAIN_VARIANT"] = "gnuarmemb"
os.environ["GNUARMEMB_TOOLCHAIN_PATH"] = "/usr"


def has_sysbuild(app_dir):
    """检查应用是否有 sysbuild 配置"""
    return (app_dir / "sysbuild" / "CMakeLists.txt").exists() or \
           (app_dir / "sysbuild.conf").exists()


def run_cmd(cmd, cwd=None, capture=False):
    """执行命令"""
    print(f"\033[36m[CMD]\033[0m {' '.join(str(c) for c in cmd)}")
    if capture:
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    else:
        r = subprocess.run(cmd, cwd=cwd)
    return r


def list_apps():
    apps = []
    for d in sorted(APPS_DIR.iterdir()):
        if d.is_dir() and (d / "CMakeLists.txt").exists():
            apps.append(d.name)
    return apps


def find_app(name):
    d = APPS_DIR / name
    if d.is_dir() and (d / "CMakeLists.txt").exists():
        return d
    return None


def build_extra_args(app_dir):
    """拼 cmake 额外参数（overlay 等）"""
    args = []
    overlay = app_dir / "boards" / (BOARD.replace("/", "_") + ".overlay")
    if overlay.exists():
        args.append(f"-DDTC_OVERLAY_FILE={overlay}")
        print(f"\033[36m[INFO]\033[0m overlay: {overlay}")
    return args


def do_build(name, app_dir):
    """编译应用（自动检测 sysbuild）"""
    bdir = BUILD_DIR / name
    use_sysbuild = has_sysbuild(app_dir) and not os.environ.get("NO_SYSBUILD")

    if bdir.exists():
        # 检查缓存是否匹配当前的编译模式
        cache = bdir / "CMakeCache.txt"
        if cache.exists():
            is_sysbuild = "sysbuild" in (bdir / "build_info.yml").read_text() if (bdir / "build_info.yml").exists() else False
            if is_sysbuild != use_sysbuild:
                print(f"\033[33m[WARN]\033[0m 编译模式变化，清理缓存")
                shutil.rmtree(bdir)

    bdir.mkdir(parents=True, exist_ok=True)
    extra = build_extra_args(app_dir)

    if use_sysbuild:
        print(f"\033[36m[INFO]\033[0m 模式: sysbuild (MCUboot + {name})")
        print(f"\033[36m[INFO]\033[0m SDK: {SDK_DIR}")
        r = run_cmd(
            ["west", "build", "--sysbuild",
             "-b", BOARD,
             str(app_dir),
             "-d", str(bdir),
             "--"] + extra,
            cwd=str(SDK_DIR / "zephyr")
        )
    else:
        print(f"\033[36m[INFO]\033[0m 模式: 单应用 (仅 {name})")
        r = run_cmd(
            ["cmake", "-GNinja",
             f"-DBOARD={BOARD}",
             f"-DZEPHYR_BASE={SDK_DIR / 'zephyr'}",
             ] + extra + [str(app_dir)],
            cwd=str(bdir))
        if r.returncode != 0:
            print("\033[31m[ERROR]\033[0m CMake 配置失败")
            sys.exit(1)
        r = run_cmd(["ninja"], cwd=str(bdir))

    if r.returncode != 0:
        print("\033[31m[ERROR]\033[0m 编译失败")
        sys.exit(1)

    # 输出产物摘要
    print(f"\n\033[32m[OK]\033[0m 编译成功: {name}")
    merged = bdir / "merged.hex"
    if merged.exists():
        print(f"  烧写: {merged} ({merged.stat().st_size // 1024} KB)")
        print(f"  烧写命令: ./build.py {name} flash-merged")
    zip_file = bdir / "dfu_application.zip"
    if zip_file.exists():
        print(f"  OTA: {zip_file} ({zip_file.stat().st_size // 1024} KB)")
    # map 文件
    zmap = bdir / name / "zephyr" / "zephyr.map"
    if not zmap.exists():
        zmap = bdir / "zephyr" / "zephyr.map"
    if zmap.exists():
        with open(zmap) as f:
            for line in f:
                if "Memory region" in line:
                    print(f"  {line}", end="")
                    for _ in range(3):
                        print(f"  {next(f)}", end="")


def do_flash(name, merged=False):
    """烧写"""
    bdir = BUILD_DIR / name
    if not bdir.exists():
        print(f"\033[31m[ERROR]\033[0m 请先编译: ./build.py {name}")
        sys.exit(1)

    if merged:
        # 烧写 merged.hex（MCUboot + app 一起）
        merged_hex = bdir / "merged.hex"
        if not merged_hex.exists():
            print(f"\033[31m[ERROR]\033[0m merged.hex 不存在，需要 sysbuild 模式编译")
            sys.exit(1)
        print(f"\033[36m[INFO]\033[0m 烧写 merged.hex (MCUboot + {name})")
        print(f"\033[36m[INFO]\033[0m 目标: {merged_hex}")
        r = run_cmd(
            ["nrfjprog", "--program", str(merged_hex), "--sectorerase", "-f", "nrf52"],
        )
        if r.returncode == 0:
            run_cmd(["nrfjprog", "--pinresetenable", "-f", "nrf52"])
            run_cmd(["nrfjprog", "--reset", "-f", "nrf52"])
            print(f"\033[32m[OK]\033[0m 烧写完成 (merged.hex)")
        else:
            print(f"\033[33m[WARN]\033[0m nrfjprog 失败，试试用 JLink:")
            print(f"  west flash --runner jlink -d {bdir}")
    else:
        # 通过 west flash
        r = run_cmd(["west", "flash", "--runner", "jlink"], cwd=str(bdir))
        if r.returncode == 0:
            print(f"\033[32m[OK]\033[0m 烧写完成: {name}")
        else:
            print(f"\033[31m[ERROR]\033[0m 烧写失败")


def do_clean(name):
    bdir = BUILD_DIR / name
    if bdir.exists():
        shutil.rmtree(bdir)
        print(f"\033[32m[OK]\033[0m 清理: {name}")


def do_new(name):
    app_dir = APPS_DIR / name
    if app_dir.exists():
        print(f"\033[31m[ERROR]\033[0m 应用已存在: {name}")
        sys.exit(1)

    (app_dir / "src").mkdir(parents=True)
    (app_dir / "boards").mkdir(parents=True)
    (app_dir / "sysbuild").mkdir(parents=True)

    # CMakeLists.txt
    (app_dir / "CMakeLists.txt").write_text(
        f"""cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{{ZEPHYR_BASE}})
project({name})
target_sources(app PRIVATE src/main.c)
""")

    # prj.conf
    (app_dir / "prj.conf").write_text(
        "CONFIG_LOG=y\nCONFIG_PRINTK=y\n")

    # main.c
    (app_dir / "src" / "main.c").write_text(
        f"""#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
LOG_MODULE_REGISTER({name}, LOG_LEVEL_INF);

int main(void) {{
    LOG_INF("{name} started on %s", CONFIG_BOARD);
    return 0;
}}
""")

    # sysbuild 配置（MCUboot 支持）
    (app_dir / "sysbuild" / "CMakeLists.txt").write_text(
        """# SPDX-License-Identifier: Apache-2.0

find_package(Sysbuild REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sysbuild LANGUAGES)
""")
    (app_dir / "sysbuild.conf").write_text(
        "# Enable MCUboot bootloader support\nSB_CONFIG_BOOTLOADER_MCUBOOT=y\n")

    print(f"\033[32m[OK]\033[0m 已创建: {name}")
    print(f"  编辑: vim {app_dir / 'src' / 'main.c'}")
    print(f"  编译: ./build.py {name}       # 自动带 MCUboot")
    print(f"  快速: ./build.py {name} no-boot  # 不带 MCUboot")


def interactive():
    apps = list_apps()
    if not apps:
        print("\033[33m[WARN]\033[0m 没有应用 (试试 ./build.py new <name>)")
        return

    print("可用应用:")
    for i, app in enumerate(apps, 1):
        tag = " [MCUboot]" if (APPS_DIR / app / "sysbuild" / "CMakeLists.txt").exists() else ""
        print(f"  [{i}] {app}{tag}")
    print("  [n] 新建应用")
    sel = input(f"选择 (1-{len(apps)}/n): ").strip()
    if sel == "n":
        name = input("应用名: ").strip()
        if name: do_new(name)
        return
    try:
        name = apps[int(sel) - 1]
    except (ValueError, IndexError):
        return

    app_dir = find_app(name)
    if not app_dir: return

    print("\n命令:")
    print("  [1] 编译")
    print("  [2] 编译 + 烧写 merged.hex")
    print("  [3] 清理")
    print("  [4] 编译 (no sysbuild)")
    cmd = input("选择 (1-4): ").strip()
    if cmd == "1": do_build(name, app_dir)
    elif cmd == "2": do_build(name, app_dir); do_flash(name, merged=True)
    elif cmd == "3": do_clean(name)
    elif cmd == "4": do_build(name, app_dir, force_no_sysbuild=True)


def help():
    print(__doc__)


def main():
    if len(sys.argv) == 1:
        interactive()
        return

    cmd = sys.argv[1]

    if cmd in ("-h", "--help", "help"):
        help()
    elif cmd == "list":
        for app in list_apps():
            tag = " [MCUboot]" if (APPS_DIR / app / "sysbuild" / "CMakeLists.txt").exists() else ""
            print(f"  - {app}{tag}")
    elif cmd == "new":
        if len(sys.argv) < 3:
            print("用法: ./build.py new <name>")
            sys.exit(1)
        do_new(sys.argv[2])
    else:
        name = cmd
        app_dir = find_app(name)
        if not app_dir:
            apps = list_apps()
            print(f"\033[31m[ERROR]\033[0m 应用不存在: {name}")
            print(f"  可用: {' '.join(apps)}")
            print(f"  新建: ./build.py new <name>")
            sys.exit(1)

        sub = sys.argv[2] if len(sys.argv) > 2 else "build"

        if sub in ("build", ""):
            do_build(name, app_dir)
        elif sub == "flash":
            do_build(name, app_dir)
            do_flash(name)
        elif sub == "flash-merged":
            do_build(name, app_dir)
            do_flash(name, merged=True)
        elif sub == "clean":
            do_clean(name)
        elif sub == "no-boot":
            os.environ["NO_SYSBUILD"] = "1"
            do_build(name, app_dir)
        else:
            print(f"\033[31m[ERROR]\033[0m 未知命令: {sub}")
            sys.exit(1)


if __name__ == "__main__":
    main()
