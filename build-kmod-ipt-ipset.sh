#!/usr/bin/env bash
# =============================================================================
#  build-kmod-ipt-ipset.sh
#
#  为 ImmortalWrt 25.12 分支 / mediatek-filogic 编译 kmod-ipt-ipset
#
#  目标设备 : Xiaomi Redmi Router AX6000 (MTK U-Boot layout)
#             profile = xiaomi_redmi-router-ax6000-ubootmod
#  目标架构 : aarch64_cortex-a53
#  目标内核 : 6.12.112
#
#  说明：openwrt-25.12 分支当前 HEAD 的内核就是 6.12.112，默认直接编分支最新代码。
#        如果你的固件内核不是 6.12.112，脚本会停下来提示，不会编出装不上的模块。
#
#  运行环境 : WSL2 (Ubuntu 22.04/24.04)、原生 Linux、GitHub Actions
#  资源需求 : 磁盘约 20 GB，耗时约 60~100 分钟（首次要编工具链）
#
#  用法:
#      bash build-kmod-ipt-ipset.sh
#
#  可覆盖的环境变量:
#      SRC=~/immortalwrt-25.12   源码目录
#      BRANCH=openwrt-25.12      分支名
#      REV=                      可选：指定提交号；留空 = 用分支最新提交
#      JOBS=8                    并行编译任务数（默认 nproc）
#      GIT_URL=...               源码仓库地址（国内可换成镜像）
#      FORCE=1                   内核版本不是 6.12.112 时也继续
# =============================================================================
set -euo pipefail

REV="${REV:-}"
BRANCH="${BRANCH:-openwrt-25.12}"
GIT_URL="${GIT_URL:-https://github.com/immortalwrt/immortalwrt.git}"
SRC="${SRC:-$HOME/immortalwrt-25.12}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
EXPECT_KVER="6.12.112"

PROFILE="xiaomi_redmi-router-ax6000-ubootmod"
TARGET_CFG="CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_${PROFILE}"

OUT="$SRC/out-kmod-ipset"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '\033[1;33m[警告] %s\033[0m\n' "$*"; }

# 读取目标内核版本：25.12 起版本号在 target/linux/generic/kernel-<patchver>
detect_kver() {
    local pv
    pv="$(sed -n 's/^KERNEL_PATCHVER:=\(.*\)/\1/p' target/linux/mediatek/Makefile 2>/dev/null | head -n1)"
    if [ -n "$pv" ] && [ -f "target/linux/generic/kernel-$pv" ]; then
        sed -n "s/^LINUX_VERSION-$pv = \.\(.*\)/$pv.\1/p" "target/linux/generic/kernel-$pv" | head -n1
    else
        sed -n 's/^LINUX_VERSION-6\.12 = \.\(.*\)/6.12.\1/p' include/kernel-version.mk 2>/dev/null | head -n1
    fi
}

# ---------------------------------------------------------------------------
#  带日志的 make 封装
#
#  重要：OpenWrt 默认是「静默模式」，include/verbose.mk 里写着
#        SILENT:=>/dev/null 2>&1
#  也就是说子 make 的 stdout/stderr 会被整个丢进 /dev/null，
#  失败时你只会看到一句 "build failed. Please re-run make with -j1 V=s"。
#  所以这里一律加 V=s，并把输出写进日志；只有失败时才把尾部打出来。
# ---------------------------------------------------------------------------
run_make() {
    local name="$1"; shift
    local log="$SRC/build-${name}.log"

    step "编译 $name : make -j$JOBS V=s $*"
    echo "    日志文件: $log"

    if make -j"$JOBS" V=s "$@" >"$log" 2>&1; then
        rm -f "$log"
        return 0
    fi

    printf '\n\033[1;31m========== %s 失败，日志最后 200 行 ==========\033[0m\n' "$*"
    tail -n 200 "$log" || true
    printf '\033[1;31m================================================\033[0m\n\n'

    # 保留日志，方便在 Actions 产物里下载
    mkdir -p "$OUT"
    cp -f "$log" "$OUT"/ 2>/dev/null || true

    die "make $* 失败（完整日志: $log）"
}

# ---------------------------------------------------------------------------
step "1/7 检查运行环境"
[ "$(uname -s)" = "Linux" ] || die "必须在 Linux / WSL2 / GitHub Actions 中运行（当前: $(uname -s)）"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
echo "内核: $(uname -r)    CPU: $(nproc)    并行: $JOBS    源码目录: $SRC"

# ---------------------------------------------------------------------------
step "2/7 安装编译依赖"
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
    gettext git libncurses-dev libssl-dev libelf-dev liblzma-dev bc \
    python3 python3-dev python3-setuptools python3-pyelftools swig \
    rsync unzip zlib1g-dev file wget ca-certificates

# ---------------------------------------------------------------------------
step "3/7 获取源码"
if [ ! -d "$SRC/.git" ]; then
    git clone "$GIT_URL" "$SRC"
fi
cd "$SRC"
git remote set-url origin "$GIT_URL"
git fetch --prune origin "+refs/heads/*:refs/remotes/origin/*"

if [ -n "$REV" ] && [ "$REV" != "HEAD" ]; then
    FULL="$(git rev-list --all | grep -m1 "^${REV}" || true)"
    [ -n "$FULL" ] || die "找不到提交 $REV（已搜索全部分支）。留空 REV 可直接用分支 $BRANCH 的最新提交。"
    echo "使用指定提交: $FULL"
    git checkout -q -f "$FULL"
else
    echo "使用分支 $BRANCH 的最新提交"
    git checkout -q -f "origin/$BRANCH"
fi
echo "当前代码: $(git log -1 --format='%H %ad %s' --date=short)"

# ---------------------------------------------------------------------------
step "4/7 校验内核版本"
KVER="$(detect_kver)"
echo "该代码的内核版本: ${KVER:-未知}"

# 如果分支已经往前走了（内核被升到 .113 之类），自动回溯到最后一个 6.12.112 的提交
if [ "$KVER" != "$EXPECT_KVER" ] && [ "${FORCE:-0}" != "1" ]; then
    WANT="${EXPECT_KVER#6.12.}"
    echo "当前不是 $EXPECT_KVER，正在回溯最后一个 $EXPECT_KVER 的提交…"
    CAND=""
    for c in $(git log --format=%H -S"LINUX_VERSION-6.12 = .${WANT}" -- target/linux/generic/kernel-6.12 | head -n 5); do
        if git show "$c:target/linux/generic/kernel-6.12" 2>/dev/null | grep -q "^LINUX_VERSION-6.12 = \.${WANT}$"; then
            CAND="$c"; break
        fi
    done
    if [ -n "$CAND" ]; then
        git checkout -q -f "$CAND"
        KVER="$(detect_kver)"
        echo "已切到 $CAND，内核版本: $KVER"
    fi
fi

if [ "$KVER" != "$EXPECT_KVER" ] && [ "${FORCE:-0}" != "1" ]; then
    die "内核版本是 ${KVER:-未知}，与路由器上的 $EXPECT_KVER 不一致，编出来的模块无法加载。
     如果确认要强制继续，请加 FORCE=1 重新运行。"
fi

# ---------------------------------------------------------------------------
step "5/7 生成配置（$PROFILE）"
cat > .config <<EOF
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_MULTI_PROFILE=y
${TARGET_CFG}=y
CONFIG_PACKAGE_kmod-ipt-ipset=m
EOF
make defconfig

grep -qE "^CONFIG_PACKAGE_kmod-ipt-ipset=(m|y)" .config || die "kmod-ipt-ipset 没有被选中，请检查 .config"
if ! grep -q "^${TARGET_CFG}=y" .config; then
    warn "设备 profile 未被选中，将按该子目标的默认 profile 继续编译。"
    echo "      （内核模块与设备无关，vermagic 仍然是 $KVER，不影响使用）"
fi

echo "--- 与本次编译相关的配置 ---"
grep -E '^CONFIG_TARGET_(mediatek|mediatek_filogic|MULTI_PROFILE|DEVICE_)' .config | head -n 20 || true
echo "----------------------------"

# ---------------------------------------------------------------------------
step "6/7 编译（工具链 → 内核 → 内核模块）"
#
# 注意顺序：target/linux/compile 只依赖 $(STAGING_DIR)/.prepared 和 $(BIN_DIR)，
# 它 **不会** 自动去编交叉工具链（那条依赖只挂在 toolchain/compile 上）。
# 少了 toolchain/install 这一步，内核一调用 aarch64-openwrt-linux-musl-gcc 就失败。
run_make toolchain toolchain/install
touch "$SRC/.toolchain-ok"          # 给 workflow 做标记：工具链编好了，可以存缓存
run_make kernel    target/linux/compile
run_make kmods     package/kernel/linux/compile

# ---------------------------------------------------------------------------
step "7/7 收集产物"
rm -rf "$OUT"; mkdir -p "$OUT"

# 1) 安装包（25.12 是 apk 格式）
while IFS= read -r f; do
    cp -v "$f" "$OUT"/
done < <(find bin \( -name 'kmod-ipt-ipset-*.apk' -o -name 'kmod-ipt-ipset-*.ipk' \) 2>/dev/null)

# 2) 直接可用的 .ko（ipset 家族 + xt_set + 依赖）
find build_dir -path "*linux-${KVER}*" \
     \( -name 'ip_set*.ko' -o -name 'xt_set.ko' -o -name 'nfnetlink.ko' \
        -o -name 'x_tables.ko' -o -name 'ip_tables.ko' \) \
     -exec cp -v {} "$OUT"/ \;

ls -1 "$OUT"/*.ko >/dev/null 2>&1 || die "没有生成任何 .ko，编译结果不完整"

( cd "$OUT" && sha256sum ./* > SHA256SUMS )

echo
echo "--- 模块 vermagic（必须与路由器 uname -r 一致，即 $KVER）---"
for f in "$OUT"/*.ko; do
    printf '  %-28s %s\n' "$(basename "$f")" "$(modinfo -F vermagic "$f" 2>/dev/null || echo '未知')"
done
echo

echo "============================================================"
echo " 产物目录: $OUT"
ls -l "$OUT"
echo "============================================================"
cat <<'TIP'

下一步：
  1) 先试标准安装（内核 config hash 完全一致时才能成功）：
       scp -O out-kmod-ipset/kmod-ipt-ipset-*.apk root@192.168.1.1:/tmp/
       ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/kmod-ipt-ipset-*.apk'

  2) 如果 apk 报 kernel 依赖不匹配（大概率），直接拷 .ko：
       scp -O out-kmod-ipset/*.ko root@192.168.1.1:/lib/modules/6.12.112/
       ssh root@192.168.1.1 'insmod /lib/modules/6.12.112/nfnetlink.ko;
                             insmod /lib/modules/6.12.112/ip_set.ko;
                             insmod /lib/modules/6.12.112/xt_set.ko'

  3) 用户态工具（如路由器上还没有）：
       apk add ipset
TIP
