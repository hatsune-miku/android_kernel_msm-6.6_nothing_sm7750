#!/bin/bash
# 构建 Nothing Phone (4a) Pro (FroggerPro / sm7750-kera) 内核。
#
# 用法:
#   ./build.sh analyze          # 只跑 bazel analysis，不编译（最快的健康检查）
#   ./build.sh dist             # 完整构建，产出 boot.img 等到 out/ 下
#   ./build.sh dist --lto=none  # 内存不够时关掉 LTO
#   TARGET_PRODUCT=Metroid ./build.sh dist   # 切到 Phone (3a) 系列
#
# 目标说明:
#   //msm-kernel:sun_perf_dist
#   FroggerPro 走 `sun` 目标（sun_perf.config 里 CONFIG_ARCH_KERA=y），
#   platform_map.bzl 的 binary_compatible_with=["tuna","kera"] 会把 kera 的
#   dtb/dtbo（含设备实际使用的 kera-qrd-wcn7750-ufs*-overlay.dtbo）并进产物。

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${WS:-$(dirname "$HERE")/kernel_platform}"
TARGET="${TARGET:-//msm-kernel:sun_perf_dist}"
MODE="${1:-analyze}"
shift || true

cd "$WS"

# bazel 7.1.1 默认开 bzlmod，但 QCOM/msm-kernel 走的是 WORKSPACE
# （@dtc、@nt_project 都定义在 msm-kernel/bazel.WORKSPACE 里），必须显式关掉。
COMMON_FLAGS=(--noenable_bzlmod)

# 本机 4 核 / 3.9 GB RAM + 7 GB swap。bazel 默认会按核数并发，
# 在这台机器上会 OOM，所以显式压低。
LOW_MEM_FLAGS=(
  "${COMMON_FLAGS[@]}"
  --jobs=2
  --local_ram_resources=2048
  --local_cpu_resources=3
  --config=local          # 减少 sandbox 开销（内存/IO）
)

case "$MODE" in
  analyze)
    echo ">>> analysis only（验证 WORKSPACE 加载 + 依赖解析，不编译）"
    exec tools/bazel build "${COMMON_FLAGS[@]}" --nobuild "$TARGET" "$@"
    ;;
  dist)
    echo ">>> 完整构建 $TARGET"
    exec tools/bazel run "${LOW_MEM_FLAGS[@]}" "$TARGET" "$@"
    ;;
  build)
    echo ">>> 只编译不 dist"
    exec tools/bazel build "${LOW_MEM_FLAGS[@]}" "$TARGET" "$@"
    ;;
  clean)
    exec tools/bazel clean --expunge
    ;;
  *)
    echo "未知模式: $MODE（可用: analyze | build | dist | clean）" >&2
    exit 1
    ;;
esac
