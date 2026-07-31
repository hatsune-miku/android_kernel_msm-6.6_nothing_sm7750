#!/bin/bash
# 一键搭建 Nothing Phone (4a) Pro (FroggerPro / sm7750) 的 kernel_platform 构建环境。
#
# 用法:
#   ./fetch_deps.sh
#   MSM_KERNEL=/path/to/android_kernel_msm-6.6_nothing_sm7750 ./fetch_deps.sh
#   WS=/mnt/big/kernel_platform ./fetch_deps.sh
#
# 幂等：已完成的项目靠 .done 标记跳过，可以随时重跑补齐。
#
# 需要的系统工具：git、curl、tar、python3。编译器/bazel/java 全部由 prebuilts 提供，
# 不需要装 clang/gcc/make/bison/flex/openjdk。
#
# ---------------------------------------------------------------------------
# 版本锁定依据（都能在 msm-kernel 树里查到，不是猜的）：
#   ACK      android15-6.6-2025-10_r7   <- msm-kernel/android/ACK_SHA
#   clang    clang-r510928              <- msm-kernel/build.config.constants
#   kleaf    clo/la/kernel/build @ kernel.lnx.6.6.r1-rel
#            <- CLO manifest KERNEL.PLATFORM.4.0.r1-17300-kernel.0.xml
#   其余     ACK manifest common-android15-6.6-2025-10 (kernel/manifest)
#
# 为什么 kleaf 必须用 CodeLinaro 版：
#   AOSP 的 kernel/build 没有 gki_ramdisk_prebuilt_binary 属性（git log -S 确认
#   历史上从未有过，是 CLO 私有补丁），而 msm_kernel_la.bzl 会把它传给
#   kernel_images，用 AOSP kleaf 会报 "no such attribute"。
#   CodeLinaro 的 git 协议可以匿名访问（网页会重定向到登录，git clone 不会）。
#
# 为什么大 prebuilts 不用 git clone：
#   git < 2.27 的 partial clone (--filter=blob:none) + sparse-checkout 组合是坏的，
#   会报 "fatal: --stdin requires a git repository / index-pack failed"。
#   改用 gitiles 的 +archive 接口按子目录下 tar.gz，任何 git 版本都能用，
#   而且只下需要的部分（clang 仓库全量有几十 GB，我们只要一个版本 3 GB）。
# ---------------------------------------------------------------------------

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(dirname "$HERE")}"

# msm-kernel 仓库位置：可用 MSM_KERNEL= 指定，否则在 $ROOT 下自动找
if [ -z "${MSM_KERNEL:-}" ]; then
  for d in "$ROOT"/*/; do
    if [ -f "$d/build.config.constants" ] && [ -f "$d/msm_kernel_extensions.bzl" ]; then
      MSM_KERNEL="${d%/}"; break
    fi
  done
fi
if [ -z "${MSM_KERNEL:-}" ] || [ ! -f "$MSM_KERNEL/build.config.constants" ]; then
  echo "找不到 msm-kernel 仓库。请用 MSM_KERNEL=/path/to/android_kernel_msm-6.6_nothing_sm7750 指定。" >&2
  exit 1
fi
MSM_KERNEL="$(cd "$MSM_KERNEL" && pwd)"

WS="${WS:-$ROOT/kernel_platform}"
LOG="${LOG:-$HERE/fetch.log}"

AOSP="https://android.googlesource.com"
CLO="https://git.codelinaro.org/clo/la"

# clang 版本从 msm-kernel 自己的配置里读，不写死
CLANG_VERSION="clang-$(sed -n 's/^CLANG_VERSION=//p' "$MSM_KERNEL/build.config.constants")"
# ACK 版本从 android/ACK_SHA 第二行（tag）读
# 默认按 android/ACK_SHA 读(源码发布对应的 ACK)。但设备实际跑的 GKI 版本
# 可能不同(见 README 坑1),可用 ACK_TAG= 覆盖成设备匹配的 tag,省一次多余下载。
ACK_TAG="${ACK_TAG:-$(sed -n 2p "$MSM_KERNEL/android/ACK_SHA" | tr -d '[:space:]')}"
KLEAF_BRANCH="kernel.lnx.6.6.r1-rel"
KBUILD_REV="main-kernel-build-2024"

# global git 里可能配了不可用的代理，显式清空
GIT="git -c http.proxy= -c https.proxy="
CURL_OPTS=(-sfL --retry 3 --retry-delay 5 --max-time 3600 --speed-time 60 --speed-limit 1024)

mkdir -p "$WS" "$(dirname "$LOG")"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { log "  !!  $1"; echo "$1" >> "$WS/.fetch_failures"; }

# gclone <dst> <url> <ref>
gclone() {
  local dst="$1" url="$2" ref="$3" full="$WS/$1"
  if [ -e "$full/.done" ]; then log "SKIP  $dst"; return 0; fi
  rm -rf "$full"; mkdir -p "$(dirname "$full")"
  log "CLONE $dst  <- $url @$ref"
  if $GIT clone --depth 1 -b "$ref" "$url" "$full" >>"$LOG" 2>&1; then
    touch "$full/.done"; log "  OK  $dst  ($(du -sh "$full" 2>/dev/null | cut -f1))"
  else
    fail "$dst"
  fi
}

# arch_get <dst> <repo-name> <ref> <root-file,...> <subdir> [subdir ...]
# 通过 gitiles +archive 按子目录取 tar.gz，不经过 git
arch_get() {
  local dst="$1" name="$2" ref="$3" rootfiles="$4"; shift 4
  local full="$WS/$dst"
  if [ -e "$full/.done" ]; then log "SKIP  $dst"; return 0; fi
  rm -rf "$full"; mkdir -p "$full"
  local ok=1

  local IFS=,
  for f in $rootfiles; do
    unset IFS; [ -z "$f" ] && continue
    log "  GET  $dst/$f"
    if ! curl "${CURL_OPTS[@]}" "$AOSP/$name/+/refs/heads/$ref/$f?format=TEXT" \
         | base64 -d > "$full/$f" 2>>"$LOG"; then
      log "       ($f 取不到，忽略)"; rm -f "$full/$f"
    fi
  done
  unset IFS

  for sub in "$@"; do
    log "  TAR  $dst/$sub"
    mkdir -p "$full/$sub"
    if ! curl "${CURL_OPTS[@]}" "$AOSP/$name/+archive/refs/heads/$ref/$sub.tar.gz" \
         | tar xz -C "$full/$sub" 2>>"$LOG"; then
      log "       $sub 解包失败"; ok=0
    fi
  done

  if [ $ok -eq 1 ]; then
    touch "$full/.done"; log "  OK  $dst  ($(du -sh "$full" 2>/dev/null | cut -f1))"
  else
    fail "$dst"
  fi
}

log "=== 搭建 $WS ==="
log "    msm-kernel : $MSM_KERNEL"
log "    ACK        : $ACK_TAG"
log "    clang      : $CLANG_VERSION"
rm -f "$WS/.fetch_failures"

# =========================================================== 1. 源码 / 构建系统
gclone common                   "$AOSP/kernel/common"                      "$ACK_TAG"
# kleaf：必须 CodeLinaro 版，见文件头说明
gclone build/kernel             "$CLO/kernel/build"                        "$KLEAF_BRANCH"
gclone build/bazel_common_rules "$AOSP/platform/build/bazel_common_rules"  "$KBUILD_REV"
gclone kernel/configs           "$AOSP/kernel/configs"                     main

# =========================================================== 2. 工具链 prebuilts
# clang：只要 build.config.constants 指定的版本 + kleaf 的 bazel 胶水目录
#        （workspace.bzl:35 会 load //prebuilts/clang/host/linux-x86/kleaf/…）
arch_get prebuilts/clang/host/linux-x86 platform/prebuilts/clang/host/linux-x86 "$KBUILD_REV" \
         "" "$CLANG_VERSION" kleaf

# build-tools：kleaf 的 hermetic 工具链
#   path/ = kleaf PATH 用的符号链接（bazel.sh 从 path/linux-x86/python3 启动）
#   sysroots/ + common/ = hermetic cc 工具链需要
arch_get prebuilts/build-tools platform/prebuilts/build-tools "$KBUILD_REV" \
         "BUILD.bazel,Android.bp,OWNERS,METADATA" \
         linux-x86 path common sysroots

# kernel-build-tools：bazel 二进制本身在 bazel/linux-x86_64/bazel（kleaf/bazel.py:29）
arch_get prebuilts/kernel-build-tools kernel/prebuilts/build-tools "$KBUILD_REV" \
         "BUILD.bazel,cc.bzl,OWNERS" \
         bazel linux-x86

arch_get prebuilts/clang-tools platform/prebuilts/clang-tools "$KBUILD_REV" \
         "BUILD.bazel,README.md" linux-x86

arch_get prebuilts/jdk/jdk11 platform/prebuilts/jdk/jdk11 "$KBUILD_REV" "" linux-x86

# NDK：hermetic-tools 依赖 @prebuilt_ndk//:sysroot（build/kernel/kleaf/ndk.BUILD），
#      glob 只要 toolchains/llvm/prebuilt/linux-x86_64/sysroot/**（约 90 MB）
arch_get prebuilts/ndk-r26 toolchain/prebuilts/ndk/r26 "$KBUILD_REV" \
         "" toolchains/llvm/prebuilt/linux-x86_64/sysroot

gclone prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8 \
       "$AOSP/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8" "$KBUILD_REV"

# =========================================================== 3. 打包 / 外部依赖
gclone tools/mkbootimg "$AOSP/platform/system/tools/mkbootimg" "$KBUILD_REV"
# msm-kernel/bazel.WORKSPACE 里的 @dtc 需要它
gclone external/dtc    "$AOSP/platform/external/dtc"           main

for p in libcap libcap-ng lz4 pigz toybox zlib zopfli; do
  gclone "external/$p" "$AOSP/platform/external/$p" "$KBUILD_REV"
done
for p in bazel-skylib bazelbuild-platforms bazelbuild-apple_support \
         bazelbuild-rules_cc bazelbuild-rules_java bazelbuild-rules_license \
         bazelbuild-rules_pkg bazelbuild-rules_python \
         bazelbuild-bazel-central-registry; do
  gclone "external/$p" "$AOSP/platform/external/$p" "$KBUILD_REV"
done
gclone external/python/absl-py "$AOSP/platform/external/python/absl-py" "$KBUILD_REV"

# =========================================================== 4. 工作区骨架
# 这几个文件不属于任何 git 仓库，必须手工建。
log "=== 建立工作区骨架 ==="

# msm-kernel 挂进工作区
if [ ! -e "$WS/msm-kernel" ]; then
  ln -s "$MSM_KERNEL" "$WS/msm-kernel"; log "  ln  msm-kernel -> $MSM_KERNEL"
fi

# 根 WORKSPACE 必须用 msm-kernel 那份：它 = kleaf 的 bazel.WORKSPACE + QCOM 的
# @dtc 定制（超集）。CLO manifest 把它链到 kleaf 那份，但那份没有 @dtc。
ln -sfn msm-kernel/bazel.WORKSPACE "$WS/WORKSPACE"
ln -sfn msm-kernel/.bazelignore    "$WS/.bazelignore"

mkdir -p "$WS/tools"
ln -sfn ../build/kernel/kleaf/bazel.sh "$WS/tools/bazel"

# //build 必须是个 bazel package，否则 //build:msm_kernel_extensions.bzl 无法解析
# （msm_platforms.bzl:1 等 7 处 load 它）。空文件即可。
if [ ! -f "$WS/build/BUILD.bazel" ]; then
  printf '# 让 //build 成为 bazel package，供 //build:msm_kernel_extensions.bzl 解析。\n' \
    > "$WS/build/BUILD.bazel"
  log "  new build/BUILD.bazel"
fi
# build_with_bazel.py:106-127 (setup_extensions) 平时会自动建这个链接
ln -sfn ../msm-kernel/msm_kernel_extensions.bzl "$WS/build/msm_kernel_extensions.bzl"

# =========================================================== 5. 校验
log "=== 校验关键文件 ==="
miss=0
for f in prebuilts/kernel-build-tools/bazel/linux-x86_64/bazel \
         prebuilts/build-tools/path/linux-x86/python3 \
         "prebuilts/clang/host/linux-x86/$CLANG_VERSION/bin/clang" \
         prebuilts/clang/host/linux-x86/kleaf/clang_toolchain_repository.bzl \
         prebuilts/kernel-build-tools/linux-x86/bin/avbtool \
         prebuilts/jdk/jdk11/linux-x86/bin/java \
         prebuilts/ndk-r26/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/stdio.h \
         external/dtc/libfdt/libfdt.h \
         build/kernel/kleaf/bazel.sh \
         common/BUILD.bazel \
         msm-kernel/nt_project.bzl ; do
  if [ -e "$WS/$f" ]; then log "  OK   $f"; else log "  MISS $f"; miss=$((miss+1)); fi
done

# kleaf 版本自检：CLO 补丁必须在
if grep -rq "gki_ramdisk_prebuilt_binary" "$WS/build/kernel/kleaf/" 2>/dev/null; then
  log "  OK   kleaf 含 CLO 的 gki_ramdisk_prebuilt_binary 补丁"
else
  log "  MISS kleaf 缺 gki_ramdisk_prebuilt_binary —— 用错了 AOSP 版 kleaf"; miss=$((miss+1))
fi

log "=== 结束 ==="
[ -f "$WS/.fetch_failures" ] && { log "拉取失败的项目："; sort -u "$WS/.fetch_failures" | tee -a "$LOG"; }
log "占用: $(du -sh --exclude=out "$WS" 2>/dev/null | cut -f1)  剩余: $(df -h "$WS" | tail -1 | awk '{print $4}')"
if [ "$miss" -eq 0 ] && [ ! -f "$WS/.fetch_failures" ]; then
  log "全部就绪。下一步： $HERE/build.sh analyze"
else
  log "有 $miss 项缺失，重跑本脚本可补齐。"; exit 1
fi
