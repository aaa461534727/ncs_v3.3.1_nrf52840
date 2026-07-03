# SDK Patches

本目录下的 `.patch` 文件会在 `build.sh` 编译前自动 apply 到 NCS SDK。

## 命名规则

`NNNN-简短描述.patch`，按文件名排序 apply。

例如：
- `0001-uart-mcumgr-debug-log.patch`
- `0002-fix-ble-scan-timeout.patch`

## 创建补丁

### 方法 1: SDK 是 git 仓库

```bash
cd ~/linux/rid/ncs/v3.3.1
# 修改 SDK 文件...
git diff > ~/linux/rid/ncs/v3.3.1-apps/apps/rid0/patches/0001-xxx.patch
# 恢复 SDK
git checkout .
```

### 方法 2: SDK 不是 git 仓库

```bash
cd ~/linux/rid/ncs/v3.3.1
# 先备份原始文件
cp zephyr/path/to/file.c /tmp/file.c.orig
# 修改 SDK 文件...
diff -u /tmp/file.c.orig zephyr/path/to/file.c > ~/linux/rid/ncs/v3.3.1-apps/apps/rid0/patches/0001-xxx.patch
# 恢复原始文件
mv /tmp/file.c.orig zephyr/path/to/file.c
```

## 路径约定

patch 文件中的路径相对于 SDK 根目录 (`ncs/v3.3.1/`)，用 `diff -u` 生成。

## 工作流

```bash
# 编译 (自动 apply patches)
./build.sh rid0

# 查看 patches 列表
./build.sh rid0 patches

# 查看 apply 状态
./build.sh rid0 patch-status

# 清理 + 回退 patches
./build.sh rid0 clean
```

## 注意事项

- `build.sh <app> build` → 自动 apply
- `build.sh <app> clean` → 自动 revert
- `build.sh <app> flash` → 先 build (含 apply) 再烧写
- 如果 patch 已经 apply 过了 (标记文件存在)，不会重复 apply
- 切换 SDK 版本时，先 `clean` 回退旧 SDK 的 patch，改 `build.sh` 里的 `SDK_DIR`，再 `build`
