# Nothing Phone (4a) Pro 内核构建环境复原记录

把 `NothingOSS/android_kernel_msm-6.6_nothing_sm7750`（分支 `sm7750/b/FroggerPro`）
恢复到可以编出 `boot.img` 的状态。

## 目录布局

```
/home/miku/repo/
├── android_kernel_msm-6.6_nothing_sm7750/   ← Nothing 发布的 msm-kernel（原始仓库）
├── kernel_platform/                          ← bazel 工作区（本次搭建）
│   ├── msm-kernel -> ../android_kernel_msm-6.6_nothing_sm7750   (符号链接)
│   ├── WORKSPACE  -> msm-kernel/bazel.WORKSPACE
│   ├── .bazelignore -> msm-kernel/.bazelignore
│   ├── tools/bazel -> ../build/kernel/kleaf/bazel.sh
│   ├── build/{kernel,bazel_common_rules,BUILD.bazel,msm_kernel_extensions.bzl}
│   ├── common/            ← ACK android15-6.6-2025-10_r7
│   ├── prebuilts/         ← clang-r510928 / build-tools / kernel-build-tools / jdk11 / ndk-r26 ...
│   ├── external/          ← dtc / bazel 规则 / hermetic 工具链源码依赖
│   └── out/               ← 构建产物
└── kp-setup/              ← 本目录：脚本 + 日志
    ├── fetch_deps.sh      ← 拉取所有依赖（可重复执行）
    ├── build.sh           ← 构建入口
    └── *.log
```

## 官方到底漏发布了什么

**只有一个**：bazel 外部仓库 `@nt_project`。

`sun.bzl:6`、`msm_kernel_la.bzl:36`、`msm_kernel_16k_la.bzl:34` 都有
`load("@nt_project//:dict.bzl", "TARGET_PRODUCT")`，但全树既没有 `dict.bzl`，
`bazel.WORKSPACE` 里也没有对应的 repository 规则 → bazel 在 load 阶段直接失败。

复原依据（契约完全可见，无需猜测）：
- `sun.bzl:345` 用它和 `"Metroid"` 比较，`sun.bzl:360` 和 `"FroggerPro"` 比较；
- `msm_kernel_la.bzl:117` / `msm_kernel_16k_la.bzl:115` 用它拼
  `build.config.nothing.{}`，而 `build.config.nothing.FroggerPro` 和
  `build.config.nothing.Metroid` 两个文件都在树里。

所以它只需导出一个字符串常量。实现见 `msm-kernel/nt_project.bzl`
（一个 `repository_rule`，默认 `FroggerPro`，可用 `TARGET_PRODUCT=Metroid` 覆盖），
并在 `msm-kernel/bazel.WORKSPACE` 末尾注册。

### 曾误判、实际不缺的

`android/gki_system_dlkm_modules` —— 它是 `BUILD.bazel:76` 的 alias，指向
`BUILD.bazel:85-93` 的 `write_file` 规则，内容从 `modules.bzl` 生成。
ACK 在 commit `a8a61755f677`（"kleaf: android/gki_system_dlkm_modules is generated"）
把它从静态文件改成了构建期生成，msm-kernel 沿用了同样的做法。

## 对 msm-kernel 仓库做的改动

只有两处，都是补官方漏发布的东西，不改任何内核逻辑：

1. 新增 `nt_project.bzl`
2. `bazel.WORKSPACE` 末尾追加 `nt_project_repository(name = "nt_project")` 的注册

## 工作区侧的必要文件（不属于任何 git 仓库，需手工建）

| 文件 | 说明 |
|---|---|
| `build/BUILD.bazel` | 空文件。让 `//build` 成为 bazel package，否则 `//build:msm_kernel_extensions.bzl` 无法解析（`msm_platforms.bzl:1` 等 7 处 load 它）。CLO manifest 里这个位置是链接到 kleaf 的 `BUILD.bazel`，但 msm-kernel 只需要 `//build` 是个 package，空文件足够。 |
| `build/msm_kernel_extensions.bzl` | 符号链接 → `../msm-kernel/msm_kernel_extensions.bzl`。由 `build_with_bazel.py:106-127` (`setup_extensions`) 自动创建，手工搭建时要自己建。 |
| `WORKSPACE` | 符号链接 → `msm-kernel/bazel.WORKSPACE`。**注意**：CLO manifest 把它链到 kleaf 的 `bazel.WORKSPACE`，但那份没有 QCOM 的 `@dtc` 定制；msm-kernel 那份 = kleaf 版 + QCOM 定制（超集），必须用它。 |

## 版本锁定依据

| 组件 | 版本 | 来源 |
|---|---|---|
| ACK (`common/`) | `android15-6.6-2025-10_r7` | `msm-kernel/android/ACK_SHA` |
| clang | `clang-r510928` | `msm-kernel/build.config.constants:1` |
| kleaf (`build/kernel`) | CodeLinaro `clo/la/kernel/build` 分支 `kernel.lnx.6.6.r1-rel` (`124a41a`) | CLO manifest `KERNEL.PLATFORM.4.0.r1-17300-kernel.0.xml` |
| 其余 prebuilts / external | ACK manifest `common-android15-6.6-2025-10` | `kernel/manifest` |

### kleaf 必须用 CodeLinaro 版，不能用 AOSP 版

AOSP 的 kleaf（`kernel/build`）**没有** `gki_ramdisk_prebuilt_binary` 属性，
而 `msm_kernel_la.bzl` / `msm_kernel_16k_la.bzl` 会把它传给 `kernel_images`，
用 AOSP kleaf 会报 `no such attribute 'gki_ramdisk_prebuilt_binary'`。
`git log -S` 确认 AOSP kleaf 历史里从未有过这个属性 → 它是 CLO 的私有补丁。

CodeLinaro 的 git 协议可以**匿名**访问（网页会重定向到登录，但 `git clone` 可以）：
- `clo/la/kernel/build` ✅
- `clo/la/kernelplatform/manifest` ✅
- `clo/la/kernel/msm-6.6` ❌ 需要认证（不过我们用 Nothing 的 fork，不需要它）

## 本机环境的两个坑

1. **git 2.25.1（Ubuntu 20.04）不能用 partial clone**
   `--filter=blob:none` + `sparse-checkout` 组合会以
   `fatal: --stdin requires a git repository` / `index-pack failed` 失败。
   所以大 prebuilts 改用 gitiles 的 `+archive` 接口按子目录下 tar.gz，完全绕开 git。

2. **global git 配置里有个死代理**
   `git config --global http.proxy = http://localhost:7897`，但 7897 没在监听。
   所有 git 命令都要加 `-c http.proxy= -c https.proxy=` 绕过。

## 用法

```bash
cd /home/miku/repo/kp-setup

./fetch_deps.sh              # 拉/补依赖（幂等，靠 .done 标记跳过已完成项）
./build.sh analyze           # 只做 bazel analysis，不编译 —— 最快的健康检查
./build.sh dist              # 完整构建，产物在 kernel_platform/out/msm-kernel-sun-perf/dist/
./build.sh dist --lto=none   # 内存不够时关掉 LTO

TARGET_PRODUCT=Metroid ./build.sh dist   # 切到 Phone (3a) 系列
```

必须带 `--noenable_bzlmod`（build.sh 已内置）：bazel 7.1.1 默认开 bzlmod，
而 `@dtc`、`@nt_project` 都定义在 WORKSPACE 里。

## 目标与产物

`//msm-kernel:sun_perf_dist`

FroggerPro 走 `sun` 目标：`arch/arm64/configs/vendor/sun_perf.config:1-3` 有
`CONFIG_ARCH_KERA=y`，`platform_map.bzl:74` 的 `binary_compatible_with = ["tuna","kera"]`
会把 kera 的 dtb/dtbo（含设备实际用的 `kera-qrd-wcn7750-ufs*-overlay.dtbo`）并进产物。

`boot.img` 的来源：`msm_kernel_la.bzl:523` 里 `build_boot = False if define_abi_targets else True`，
而 perf 变体 `define_abi_targets = True`（`:473`）→ `:289-292` 走
`artifacts = "{}_gki_artifacts".format(base_kernel)`，即 **boot.img 直接来自
`//common:kernel_aarch64` 的 GKI 产物**。签名用的是
`//tools/mkbootimg:gki/testdata/testkey_rsa4096.pem`（AVB **测试**密钥，`:299`），
所以刷机需要解锁 bootloader 并禁用 verification。

## 状态：已实机验证 ✅

自编 boot.img 已在 Nothing Phone (4a) Pro 上正常启动。

```
内核     6.6.92-android15-8-maybe-dirty-4k
lsmod    519（与原厂完全一致）
KernelSU LKM 正常工作，root 可用
```

完整流程：
```bash
./fetch_deps.sh                                    # 搭环境
# common/ 切到与设备 uname -r 匹配的 ACK tag（见坑 1）
# 应用 gki_defconfig-no-sig-protect.patch（见坑 3）
./build.sh build                                   # 或只编 boot：见下
./resign_boot.sh <编出的boot.img> <原厂boot.img>    # 见坑 2
fastboot flash boot <重签后的>.img
```

只要 boot.img（保留原厂 vendor_dlkm）的话，用这个 target 快得多，
它只依赖 GKI，不编那 347 个 msm 模块：
```bash
./tools/bazel build --noenable_bzlmod //msm-kernel:sun_perf_avb_sign_boot_image
```

## 刷机排查记录：三个必须处理的坑

自编 boot.img 在这台设备上要能起来，有三处和"直接把编出来的 boot.img 刷进去"不同的地方。
按发现顺序（也是踩坑顺序）记录。

### 坑 1：GKI 版本要对齐设备固件，不是对齐源码发布

`android/ACK_SHA` 写的是**源码发布**对应的 ACK（`android15-6.6-2025-10_r7` / 6.6.102），
但设备上跑的 GKI 是另一回事。判据是设备的 `uname -r`：

```
6.6.92-android15-8-g3637f4904cf5-ab13944661-4k
                    ^^^^^^^^^^^^  ACK commit   ^^^^^^^^^^ Google CI 构建号
```

`ab13944661` 说明 Nothing 没自己编 GKI，直接用了 Google 认证的预编译二进制。
那个 commit 对应 ACK tag `android15-6.6-2025-07_r10`（SUBLEVEL=92）。

对齐方法：
```bash
cd kernel_platform/common
git fetch --depth 1 origin refs/tags/<tag>:refs/tags/<tag>
git checkout <tag>
```

注：单靠这一条并不能让设备启动（见坑 3），但版本对齐本身是必要的。

### 坑 2：AVB 元数据是占位值，会被防回滚拒绝

`msm_kernel_la.bzl:300-302` 把 props 硬编码成了占位值，
`avb_boot_img.bzl` 又根本没传 `--rollback_index`：

|  | 原厂 | 构建产物 |
|---|---|---|
| os_version | 15 | **13** |
| security_patch | 2025-09-05 | **2023-05-05** |
| rollback index | 1757030400 | **0** |

在 bootloader 看来这是一次从 Android 15 / 2025-09 到 Android 13 / 2023-05 的大降级。
**AVB 防回滚索引存在 RPMB 里，和 bootloader 是否解锁是两套独立机制**，解锁不会让它放行。

症状：卡在第一屏，进不去，重启后自动进 recovery。

修复：用 `resign_boot.sh` 重签（会自动从原厂镜像读取正确的元数据）。
```bash
./resign_boot.sh <编出的 boot.img> <原厂 boot.img>
```

### 坑 3（真正的拦路虎）：原厂 system_dlkm 模块无法在自编内核上加载

症状：能进到开机动画，`system_server` 起来了，但音频 HAL 永远起不来，
约 5 分钟后看门狗重启。

诊断的关键是 `lsmod` 对照：自编内核 424 个模块，原厂 519 个，**差的 95 个
全部是 `/system_dlkm` 里的 GKI 模块**，外加依赖它们的 `btpower`/`cfg80211`/
`qca_cld3_qca6750` 等。日志里：

```
E modprobe: Failed to load module /system_dlkm/lib/modules/6lowpan.ko: Permission denied
init: Service 'gki.modprobe' (pid 409) exited with status 1
```

`gki.modprobe` 在字母序第一个模块就失败退出，95 个全军覆没。

机制（`common/kernel/module/main.c:1165-1172`）：

```c
is_vendor_module = !mod->sig_ok;          /* 验签失败 → 当作 vendor 模块 */
if (is_vendor_module && !is_vendor_exported_symbol &&
    !gki_is_module_unprotected_symbol(name)) {
        fsa.sym = ERR_PTR(-EACCES);        /* Permission denied */
```

原厂 `system_dlkm` 的 GKI 模块由 **Google 的构建密钥**签名，自编内核内嵌的是
**自己生成的密钥**，验签必然失败 → `sig_ok=0` → 被当成 vendor 模块 →
它们用的 GKI 内部符号不在 unprotected 列表里 → `-EACCES`。

而真正的 vendor 模块本来就不签名（`sun_perf.config:107` 是
`# CONFIG_MODULE_SIG_ALL is not set`）且只用 KMI 符号，所以照常加载。
这正好解释了 424 全过、95 全挂。

两种修法：

**A. 连 system_dlkm 一起替换成自编的**（保留 GKI 符号保护）。
   构建 `//common:kernel_aarch64_images`，取 `system_dlkm.flatten.erofs.img`
   （设备用 erofs 挂载），通过 fastbootd 刷进 super 里的逻辑分区。
   语义上最正确，但要多刷一个分区，恢复也更麻烦。

**B. 关掉 `CONFIG_MODULE_SIG_PROTECT`**（见 `gki_defconfig-no-sig-protect.patch`）。
   关掉后 `MODULE_SIG_FORCE` 未设置，异签名模块可正常加载。只需重刷 boot.img。
   代价是放弃 GKI 符号保护——在一台已 root 的个人设备上不构成实质性额外风险。

### 诊断方法论备注

前三次假设（LTS 版本不匹配、ADSP 固件加载失败、SELinux）**全部猜错**，
每次都是从症状向前推理。真正定位靠的是**对照实验**：在自编内核和原厂内核上
采集同一组 `dmesg` / `logcat` / `lsmod` / `getprop`，然后 diff。
`lsmod` 的 424 vs 519 一眼就指出了方向。

以后遇到类似问题，先做对照，别急着推理。

## 换到另一台机器编译

### 不要把工作区传到 GitHub

实测源码 6.1 GB（clang 3.0G + common 1.8G + 其他 prebuilts 1.3G），其中
**8 个文件超过 GitHub 的 100 MB 硬限制**（push 会被直接拒绝，不是警告）：

```
251M  common/.git/objects/pack/*.pack
191M  prebuilts/clang/host/linux-x86/clang-r510928/lib/libclang-cpp.so
162M  .../liblldb.so
136M  prebuilts/jdk/jdk11/linux-x86/lib/modules
128M  .../bin/clang-18
115M  .../libLLVM-18.so
115M  .../libclang.so
112M  prebuilts/clang-tools/linux-x86/lib64/libclang-cpp.so
```

Git LFS 免费额度 1 GB 存储 / 1 GB 月流量，差一个数量级。而且这些全是
Google / CodeLinaro 公开可下载的东西。

### 要传的是配方（约 15 KB）

放到 GitHub 的应该是：

1. **fork Nothing 的内核仓库**，把 `nt_project.patch` 里的两处改动提交上去
   （新增 `nt_project.bzl` + `bazel.WORKSPACE` 追加注册）。改动属于这个仓库。
2. **`kp-setup/` 这个目录**（`fetch_deps.sh` + `build.sh` + `README.md`），
   可以直接放进上面那个 fork，或单独一个小仓库。

### 新机器上的步骤

```bash
git clone -b sm7750/b/FroggerPro <你的 fork> android_kernel_msm-6.6_nothing_sm7750
git clone <kp-setup 仓库> kp-setup     # 若已并入 fork 则跳过
cd kp-setup && ./fetch_deps.sh         # 约 10 分钟拉完 6.1 GB
./build.sh analyze                     # 应输出 "Build completed successfully"
./build.sh dist
```

`fetch_deps.sh` 不含任何硬编码路径：它按脚本所在目录推导 `ROOT`，
自动在同级目录里找 msm-kernel（认 `build.config.constants` +
`msm_kernel_extensions.bzl` 两个特征文件），也可以用
`MSM_KERNEL=` / `WS=` / `ROOT=` 覆盖。clang 版本从 `build.config.constants` 读，
ACK tag 从 `android/ACK_SHA` 读，不会写死。

脚本结尾会校验 11 个关键文件 + 自检 kleaf 是否含 CLO 的
`gki_ramdisk_prebuilt_binary` 补丁（防止误用 AOSP 版 kleaf）。

### 如果新机器到 Google 的带宽很差

直接机器间传比走 GitHub 好得多：

```bash
# 只传源码，跳过构建产物和 git 元数据
rsync -a --info=progress2 \
  --exclude='out/' --exclude='.git/' --exclude='.repo/' \
  /home/miku/repo/kernel_platform/ newhost:/path/kernel_platform/
```

注意 `kernel_platform/msm-kernel` 是符号链接，`rsync -a` 会原样保留链接，
新机器上要保证指向存在——或者传完后重新 `ln -s`。
`out/` 一定不要传（bazel 里全是绝对路径，换机器必然失效，重新编即可）。

### 新机器建议配置

| 项 | 建议 | 理由 |
|---|---|---|
| RAM | ≥ 16 GB | 本机 3.9 GB 只能 `--jobs=2`，且 ThinLTO 链接有 OOM 风险 |
| CPU | ≥ 8 核 | 内核 + 347 个模块 |
| 磁盘 | ≥ 60 GB 空闲 | 源码 6.1 GB + `out/` 可到 30 GB+ |
| git | ≥ 2.27 | 不强制（脚本用 tarball 绕开了 partial clone） |
| 系统 | glibc 的发行版 | prebuilts 是为 glibc 编的；Alpine/musl 不行 |

内存够的话去掉低内存参数会快很多：`./build.sh build --jobs=$(nproc)`。

## 本机硬件限制

4 核 / 3.9 GB RAM + 7 GB swap / 磁盘占用约 6 GB 源码 + 构建产物。
内存是主要瓶颈：`--jobs=2 --local_ram_resources=2048 --config=local`。
若 vmlinux 的 ThinLTO 链接阶段 OOM，加 `--lto=none`
（不改 KMI 符号 CRC，不影响原厂 vendor_dlkm 模块加载）。
