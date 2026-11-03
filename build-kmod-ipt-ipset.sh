#!/usr/bin/env bash
# =============================================================================
#  build-kmod-ipt-ipset.sh
#
#  为 ImmortalWrt 25.12 分支 / mediatek-filogic 编译 kmod-ipt-ipset
#
#  目标设备 : Xiaomi Redmi Router AX6000 (MTK U-Boot layout)
#             profile = xiaomi_redmi-router-ax6000-ubootmod
#  目标架构 : aarch64_cortex-a53
#  目标内核 : 6.12.112   （对应固件版本 r38511-a99b0888b8）
#
#  运行环境 : WSL2 (Ubuntu 22.04/24.04)、原生 Linux，或 ubuntu:24.04 容器
#  资源需求 : 磁盘约 15~25 GB，耗时约 1~2 小时（取决于 CPU 与网络）
#
#  用法:
#      bash build-kmod-ipt-ipset.sh
#
#  可覆盖的环境变量:
#      SRC=~/immortalwrt-25.12   源码目录（默认家目录下）
#      REV=a99b0888b8            固件版本字符串里的提交号
#      BRANCH=openwrt-25.12      分支名
#      JOBS=8                    并行编译任务数（默认 nproc）
#      GIT_URL=...               源码仓库地址（国内可换成镜像）
#      FORCE=1                   内核版本不是 6.12.112 时也继续
# =============================================================================
set -euo pipefail

REV="${REV:-a99b0888b8}"
BRANCH="${BRANCH:-openwrt-25.12}"
GIT_URL="${GIT_URL:-https://github.com/immortalwrt/immortalwrt.git}"
SRC="${SRC:-$HOME/immortalwrt-25.12}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
EXPECT_KVER="6.12.112"

PROFILE="xiaomi_redmi-router-ax6000-ubootmod"
TARGET_CFG="CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_${PROFILE}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
step "1/6 检查运行环境"
if [ "$(uname -s)" != "Linux" ]; then
    die "必须在 Linux / WSL2 中运行（当前: $(uname -s)）"
fi
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
echo "内核: $(uname -r)    CPU: $(nproc)    源码目录: $SRC"

# ---------------------------------------------------------------------------
step "2/6 安装编译依赖"
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
    gettext git libncurses-dev libssl-dev libelf-dev bc \
    python3 python3-setuptools python3-pyelftools \
    rsync unzip zlib1g-dev file wget ca-certificates

# ---------------------------------------------------------------------------
step "3/6 获取源码并切到固件对应的提交 $REV"
if [ ! -d "$SRC/.git" ]; then
    git clone --filter=blob:none "$GIT_URL" "$SRC"
fi
cd "$SRC"
git remote set-url origin "$GIT_URL"
git fetch --prune origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"

FULL="$(git rev-list "origin/$BRANCH" | grep -m1 "^${REV}" || true)"
if [ -z "$FULL" ]; then
    echo "分支 $BRANCH 里没有 $REV，尝试在所有已抓取的分支中查找…"
    FULL="$(git rev-list --all | grep -m1 "^${REV}" || true)"
fi
[ -n "$FULL" ] || die "找不到提交 $REV。请确认分支名（当前 $BRANCH），或换一个能访问的 GIT_URL 镜像。"
echo "提交: $FULL"
git checkout -q -f "$FULL"

# ---------------------------------------------------------------------------
step "4/6 校验内核版本"
KVER="$(sed -n 's/^LINUX_VERSION-6\.12 = \.\(.*\)/6.12.\1/p' include/kernel-version.mk 2>/dev/null | head -n1 || true)"
[ -n "$KVER" ] || KVER="$(grep -oE 'LINUX_VERSION-[0-9.]+ = \.[0-9]+' include/kernel-version.mk 2>/dev/null | head -n1 || true)"
echo "该提交的内核版本: ${KVER:-未知}"
if [ "$KVER" != "$EXPECT_KVER" ] && [ "${FORCE:-0}" != "1" ]; then
    die "内核版本是 ${KVER:-未知}，与固件的 $EXPECT_KVER 不一致，编出来的模块无法加载。
     如果确认要强制继续，请加 FORCE=1 重新运行。"
fi

# ---------------------------------------------------------------------------
step "5/6 生成配置（$PROFILE）并开始编译"
cat > .config <<EOF
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
${TARGET_CFG}=y
CONFIG_PACKAGE_kmod-ipt-ipset=m
EOF
make defconfig
grep -q "^CONFIG_PACKAGE_kmod-ipt-ipset=m" .config \
    || die "kmod-ipt-ipset 没有被选中，请检查 .config"
grep -q "^${TARGET_CFG}=y" .config \
    || die "设备 profile 没有被选中，请检查 .config"

# 先编内核（模块依赖内核源码树），再编内核模块包
make -j"$JOBS" target/linux/compile V=s
make -j"$JOBS" package/kernel/linux/compile V=s

# ---------------------------------------------------------------------------
step "6/6 收集产物"
OUT="$SRC/out-kmod-ipset"
rm -rf "$OUT"; mkdir -p "$OUT"

shopt -s nullglob
for f in bin/targets/mediatek/filogic/kmods/*/kmod-ipt-ipset-*.apk; do
    cp -v "$f" "$OUT"/
done
find build_dir -path "*linux-${KVER}*" \
     \( -name 'ip_set*.ko' -o -name 'xt_set.ko' -o -name 'nfnetlink.ko' \) \
     -exec cp -v {} "$OUT"/ \;
shopt -u nullglob

( cd "$OUT" && sha256sum ./* > SHA256SUMS )

echo
echo "============================================================"
echo " 产物目录: $OUT"
ls -l "$OUT"
echo "============================================================"
cat <<'TIP'

下一步：
  1) 先试标准安装（内核 config hash 完全一致时才能成功）：
       scp out-kmod-ipset/kmod-ipt-ipset-*.apk root@192.168.1.1:/tmp/
       ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/kmod-ipt-ipset-*.apk'

  2) 如果 apk 报 kernel 依赖不匹配（大概率），直接拷 .ko：
       scp out-kmod-ipset/*.ko root@192.168.1.1:/lib/modules/6.12.112/
       ssh root@192.168.1.1 'depmod -a; modprobe nfnetlink; modprobe ip_set; modprobe xt_set'

  3) 用户态工具（如路由器上还没有）：
       apk add ipset
TIP
