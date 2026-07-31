#!/bin/bash
# 在 fetch_deps.sh 搭好的工作区上,应用全部内核侧改动,得到"全 patch 内核"源码树:
#   - GKI 版本对齐到设备固件 (坑 1)
#   - 关闭 MODULE_SIG_PROTECT,放行原厂 system_dlkm (坑 3)
#   - 内核版本串伪装成原厂 (坑 4)
#   - 集成 ReSukiSU root (内建,tracepoint hook) + SUSFS
#
# 前置: 先跑 ./fetch_deps.sh。之后跑本脚本,再 ./build.sh dist,产物用 ./resign_boot.sh 重签。
#
# 幂等: 每步都先检测是否已应用,可重复执行。
# 撤销: ./apply_patches.sh --revert  把 common/ 和 build/kernel 还原干净。
#
# 注意: msm-kernel 自身的 @nt_project 复原 (坑 0) 不在这里 —— 它是 patches/msm-kernel/
#       下的改动,已直接提交进 fork,fetch 时就带着。

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$HERE")}"
WS="${WS:-$ROOT/kernel_platform}"
P="$HERE/patches"

# ============================================================ 版本锁定(可复现)
# 设备 GKI 版本 —— 必须匹配设备的 uname -r 里的 ACK commit。
# 本机: 6.6.92-android15-8-g3637f4904cf5-...  → tag android15-6.6-2025-07_r10
# OTA 升级后需按新的 uname -r 改这里。
DEVICE_ACK_TAG="${DEVICE_ACK_TAG:-android15-6.6-2025-07_r10}"

# ReSukiSU 内核端,与设备上的管理器 (ReSukiSU v4.1.0 / 版本码 35040) 同源。
# 版本码 = 30000 + git提交数 + 700。此 commit 对应 4340 提交 → 35040。
RESUKISU_URL="https://github.com/ReSukiSU/ReSukiSU"
RESUKISU_COMMIT="${RESUKISU_COMMIT:-88dbc78682a3364d27ad34551943e18615abf868}"

GIT="git -c http.proxy= -c https.proxy="
COMMON="$WS/common"
KLEAF="$WS/build/kernel"

log() { echo "[apply] $*"; }
die() { echo "[apply][ERROR] $*" >&2; exit 1; }

[ -d "$COMMON/.git" ] || die "找不到 $COMMON,先跑 ./fetch_deps.sh"
[ -d "$KLEAF/kleaf" ] || die "找不到 kleaf,先跑 ./fetch_deps.sh"

# ---------------------------------------------------------------- 撤销模式
if [ "${1:-}" = "--revert" ]; then
  log "还原 common/ ..."
  ( cd "$COMMON"
    git checkout -- . 2>/dev/null || true
    rm -rf KernelSU drivers/kernelsu fs/susfs.c \
           include/linux/susfs.h include/linux/susfs_def.h
    find . -name '*.rej' -o -name '*.orig' 2>/dev/null | grep -v '^\./KernelSU' | xargs -r rm -f )
  log "还原 build/kernel/kleaf ..."
  ( cd "$KLEAF"; git checkout -- kleaf/impl/stamp.bzl 2>/dev/null || true )
  log "已还原。"
  exit 0
fi

# ============================================================ 1. GKI 版本对齐
log "1/5 对齐 GKI 版本到 $DEVICE_ACK_TAG"
cur_tag="$( $GIT -C "$COMMON" describe --tags --exact-match HEAD 2>/dev/null || true )"
if [ "$cur_tag" != "$DEVICE_ACK_TAG" ]; then
  $GIT -C "$COMMON" fetch --depth 1 origin \
      "refs/tags/$DEVICE_ACK_TAG:refs/tags/$DEVICE_ACK_TAG" 2>/dev/null || true
  $GIT -C "$COMMON" checkout -q "$DEVICE_ACK_TAG" \
      || die "无法切到 $DEVICE_ACK_TAG,确认 tag 名与设备 uname -r 匹配"
fi
log "    common/ = $(sed -n '2,4p' "$COMMON/Makefile" | tr '\n' ' ')"

# ============================================================ 2. scmversion 伪装
log "2/5 内核版本串伪装 (build/kernel/kleaf/impl/stamp.bzl)"
if grep -q "maybe-dirty" "$KLEAF/kleaf/impl/stamp.bzl" \
   && ! grep -q "g3637f4904cf5" "$KLEAF/kleaf/impl/stamp.bzl"; then
  ( cd "$KLEAF" && patch -p1 < "$P/build-kernel/01-scmversion.patch" )
else
  log "    已应用,跳过"
fi

# ============================================================ 3. gki_defconfig
log "3/5 gki_defconfig: 关 MODULE_SIG_PROTECT + 开 CONFIG_KSU_SUSFS"
if grep -q "CONFIG_MODULE_SIG_PROTECT=y" "$COMMON/arch/arm64/configs/gki_defconfig"; then
  ( cd "$COMMON" && patch -p1 < "$P/common/01-gki_defconfig.patch" )
else
  log "    已应用,跳过"
fi

# ============================================================ 4. ReSukiSU 集成
log "4/5 集成 ReSukiSU root (与设备管理器同源)"
if [ ! -d "$COMMON/KernelSU" ]; then
  ( cd "$COMMON"
    $GIT clone "$RESUKISU_URL" KernelSU
    $GIT -C KernelSU fetch --unshallow 2>/dev/null || $GIT -C KernelSU fetch --depth 100000 2>/dev/null || true
    $GIT -C KernelSU checkout -q "$RESUKISU_COMMIT" )
fi
ver=$( cd "$COMMON/KernelSU" && expr 30000 + "$($GIT rev-list --count HEAD)" + 700 )
log "    ReSukiSU 版本码 = $ver (设备管理器应为 35040)"
[ "$ver" = "35040" ] || log "    ⚠️  版本码与预期 35040 不符,管理器可能不匹配"
# 接线 (幂等)
ln -sfn ../KernelSU/kernel "$COMMON/drivers/kernelsu"
grep -q "kernelsu" "$COMMON/drivers/Makefile" \
  || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$COMMON/drivers/Makefile"
grep -q 'source "drivers/kernelsu/Kconfig"' "$COMMON/drivers/Kconfig" \
  || sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$COMMON/drivers/Kconfig"

# ============================================================ 5. SUSFS 内核补丁
log "5/5 SUSFS 内核补丁 (只打内核那半;KernelSU 那半 ReSukiSU 自带)"
cp "$P/common/susfs/susfs.c" "$COMMON/fs/"
cp "$P/common/susfs/susfs.h" "$P/common/susfs/susfs_def.h" "$COMMON/include/linux/"
if ! grep -q "susfs" "$COMMON/fs/Makefile"; then
  ( cd "$COMMON"
    # 主补丁: fs/proc/base.c 会有 1 个 hunk 因 6.6.92 缺 dma-buf.h 上下文而失败,忽略
    patch -p1 --forward < "$P/common/susfs/50_add_susfs_in_gki-android15-6.6.patch" || true
    rm -f fs/proc/base.c.rej
    # 补失败的 base.c hunk
    patch -p1 --forward < "$P/common/02-fs_proc_base_susfs_include.patch"
    find . -name '*.orig' -not -path './KernelSU/*' -delete 2>/dev/null || true )
else
  log "    已应用,跳过"
fi

echo
log "完成。验证:"
log "  common/ = $(sed -n '2,4p' "$COMMON/Makefile" | tr '\n' ' ')"
log "  ReSukiSU 版本码 = $ver"
log "  susfs.c: $([ -f "$COMMON/fs/susfs.c" ] && echo OK || echo 缺失)"
log "  selinux_hide hook: $(grep -c ksu_selinux_hide_running "$COMMON/security/selinux/hooks.c")"
echo
log "下一步: ./build.sh dist   然后   ./resign_boot.sh <产物> <原厂boot.img>"
