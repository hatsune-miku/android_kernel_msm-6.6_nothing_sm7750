#!/bin/bash
# 用与设备固件一致的 AVB 元数据重签 boot.img。
#
# 为什么需要这一步：
#   msm_kernel_la.bzl:300-302 把 AVB props 硬编码成了占位值
#       com.android.build.boot.os_version:13
#       com.android.build.boot.security_patch:2023-05-05
#   而且 avb_boot_img.bzl 的 add_hash_footer 没有传 --rollback_index，默认是 0。
#
#   于是自编镜像在 bootloader 眼里是一次大降级：
#       Android 15 / 2025-09-05 / rollback 1757030400
#         ->  Android 13 / 2023-05-05 / rollback 0
#   AVB 防回滚保护会拒绝它。防回滚索引存在 RPMB 里，和 bootloader 解锁状态是
#   两套独立机制，解锁并不会让它放行。
#
# 用法：
#   ./resign_boot.sh <构建出的 boot.img> [原厂 boot.img]
#
#   给了原厂镜像就自动从中读取 rollback index / props；否则用下面的默认值
#   （对应 FroggerPro-B4.1-260323-1635 / 安全补丁 2025-09-05）。
#
# 注意：签名用的仍然是 AVB 测试密钥（Nothing 的私钥拿不到），所以设备必须保持
#      解锁。如果重签后依然起不来，下一步是给 vbmeta 打 disable 标志：
#          fastboot --disable-verification flash vbmeta_<槽> <原厂vbmeta.img>

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${WS:-$(dirname "$HERE")/kernel_platform}"
AVB="$WS/prebuilts/kernel-build-tools/linux-x86/bin/avbtool"
KEY="${KEY:-$WS/tools/mkbootimg/gki/testdata/testkey_rsa4096.pem}"

SRC="${1:?用法: $0 <boot.img> [原厂boot.img]}"
STOCK="${2:-}"
OUT="${OUT:-${SRC%.img}-resigned.img}"

[ -x "$AVB" ] || { echo "找不到 avbtool: $AVB" >&2; exit 1; }
[ -f "$KEY" ] || { echo "找不到签名密钥: $KEY" >&2; exit 1; }

# 默认值（FroggerPro / 2025-09-05）
ROLLBACK=1757030400
OS_VERSION=15
SECURITY_PATCH=2025-09-05
FINGERPRINT='Nothing/FroggerPro/FroggerPro:15/AQ3A.250924.001/2603231635:user/release-keys'
PART_SIZE=100663296

# 有原厂镜像就以它为准，避免手工填错
if [ -n "$STOCK" ]; then
  echo ">>> 从 $STOCK 读取 AVB 元数据"
  info="$("$AVB" info_image --image "$STOCK")"
  ROLLBACK=$(sed -n 's/^Rollback Index: *//p'  <<<"$info" | head -1)
  PART_SIZE=$(sed -n 's/^Image size: *\([0-9]*\).*/\1/p' <<<"$info" | head -1)
  v=$(sed -n "s/.*com.android.build.boot.os_version -> '\(.*\)'.*/\1/p"     <<<"$info" | head -1)
  s=$(sed -n "s/.*com.android.build.boot.security_patch -> '\(.*\)'.*/\1/p" <<<"$info" | head -1)
  f=$(sed -n "s/.*com.android.build.boot.fingerprint -> '\(.*\)'.*/\1/p"    <<<"$info" | head -1)
  [ -n "$v" ] && OS_VERSION="$v"
  [ -n "$s" ] && SECURITY_PATCH="$s"
  [ -n "$f" ] && FINGERPRINT="$f"
fi

echo ">>> 目标元数据"
echo "    rollback index : $ROLLBACK"
echo "    os_version     : $OS_VERSION"
echo "    security_patch : $SECURITY_PATCH"
echo "    partition size : $PART_SIZE"

cp "$SRC" "$OUT"
"$AVB" erase_footer --image "$OUT" 2>/dev/null || true
"$AVB" add_hash_footer \
  --image "$OUT" \
  --partition_name boot \
  --partition_size "$PART_SIZE" \
  --algorithm SHA256_RSA4096 \
  --key "$KEY" \
  --rollback_index "$ROLLBACK" \
  --prop "com.android.build.boot.os_version:$OS_VERSION" \
  --prop "com.android.build.boot.security_patch:$SECURITY_PATCH" \
  --prop "com.android.build.boot.fingerprint:$FINGERPRINT"

echo ">>> 完成: $OUT"
echo "    sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
if [ -n "$STOCK" ]; then
  # 只比 rollback index 和 props；镜像大小和摘要必然不同（内核本来就改过），
  # 公钥也必然不同（拿不到 Nothing 私钥）。
  echo ">>> 与原厂的防回滚元数据对比"
  if diff <("$AVB" info_image --image "$STOCK" | grep -E "^Rollback Index:|^    Prop:" | sort) \
          <("$AVB" info_image --image "$OUT"   | grep -E "^Rollback Index:|^    Prop:" | sort); then
    echo "    一致 ✅"
  else
    echo "    ⚠️  不一致，防回滚可能仍会拒绝" >&2
    exit 1
  fi
fi
