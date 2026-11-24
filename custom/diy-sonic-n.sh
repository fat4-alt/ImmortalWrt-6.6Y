#!/bin/sh
# ============================================================
#  sonic-fullcone 版  +  custom/ 扁平三文件「只添加，不覆盖」模式
#
#  把 Yuzhii0718 树自带的 kmod-nft-fullcone（独立 nft_fullcone.ko）
#  整体替换为 mufeng05/openwrt-sonic-fullcone（984/985/986/987 内核补丁
#  + 改 nft_masq.c 内建 fullcone 表达式 + per-zone/per-proto fw4 规则）。
#
#  custom/ 里仍只有 3 个文件，没有子文件夹：
#   * d.txt = dts 内容        -> target/linux/mediatek/dts/<名字>.dts（新建/追加）
#   * f.txt = filogic.mk 片段  -> 追加到 filogic.mk 末尾
#   * n.txt = 02_network 片段  -> 插入到 case $board in 之后
#  上游源码文件一律不删行、不整文件覆盖；带幂等标记，重跑不重复。
#
#  保留前版全部约定：
#   * 原仓库 diy.sh 8 行逐字保留
#   * bind_rate 保持 30，一个字不碰；HNAT/PPE 硬件加速全开
#   * TurboACC 与 firewall 解耦（不写 nat_mode、不 reload firewall）
#   * UI 精简：CPU Usage / 活动连接(Conntrack) / ppenum 下拉 / fullcone 下拉全删
#   * Python 精确变换 + 行级兜底 + 强制自检，任一未达标立即终止编译
#
#  内核补丁 10 个全部内联在本文件里，云编译不需要额外联网、不需要上传别的目录。
#
#  本版新增两处：
#   A) fullcone 开关放回「网络 → 防火墙」页面：提前拉取 luci feed，
#      把 sonic 官方 001-add-fullcone-options.patch 作为未跟踪文件放进
#      luci-app-firewall/patches/；官方补丁 hunk 不匹配时自动按锚点
#      行号生成自适应补丁，双路径都带 dry-run 预检与降级。
#   B) TurboACC 状态栏显示修复：rpcd 改用 /usr/sbin/nft 绝对路径，
#      JS 加 formatStatType 映射 + renderStatus 防空 + 去掉「Collecting data」卡顿。
#
#  本版（v7）新增 C)：开机默认设置好，刷完无需任何 SSH 命令
#   * root/etc/uci-defaults/turboacc：仅当选项「缺失」时补两层开关 + udp
#     （刷机勾「保留配置」也不会把出厂默认值盖没；用户显式设 0 不覆盖）
#   * root/etc/init.d/turboacc：start_service 末尾加后台 12 秒自愈，
#     规则 0 条 → firewall reload 一次；ubus 不通 → rpcd restart 一次
#     不覆盖 boot()/start 启动链，正常开机零干预
# ============================================================

# ---------------- 原 diy.sh 内容开始（逐字保留） ----------------
# Modify default IP
# sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# Modify default theme
sed -i 's/luci-theme-argon/luci-theme-bootstrap/g' feeds/luci/collections/luci/Makefile

# Modify hostname
sed -i 's/ImmortalWrt/WMYWrt/g' package/base-files/files/bin/config_generate
# ---------------- 原 diy.sh 内容结束 ----------------

# 注：上面改主题那行 sed 在 workflow 里执行时 feeds 尚未拉取，
#     会打印一条 No such file or directory。原仓库本来就有，脚本无 set -e，
#     不影响编译，请勿删除。

# ============================================================
# 0/4 应用 custom/ 的三个纯文本文件（只添加，不覆盖）
# ------------------------------------------------------------
# GitHub Actions 不会自动读取 custom/，必须由本段显式处理。
# 时序：本脚本在 workflow 步骤 5 执行，cwd = /workdir/openwrt 源码根，
#       $GITHUB_WORKSPACE = 检出仓库根；dts / filogic.mk / board.d 在步骤 8
#       编译或打包阶段才被读取，此时增补完全来得及。
#
# 三个文件都是【纯内容】，没有子目录，可直接用 Upload files 拖拽上传：
#   d.txt  dts 文件内容      -> dts 目录（文件名自动推导）
#   f.txt  filogic.mk 片段   -> 追加到 filogic.mk 末尾
#   n.txt  02_network 片段   -> 插入到 case $board in 之后
# 上游文件一行不删、不整文件覆盖；带 ### >>> 幂等标记，重跑自动跳过。
# ============================================================
CUSTOM="${GITHUB_WORKSPACE}/custom"
D="$CUSTOM/d.txt"
F="$CUSTOM/f.txt"
N="$CUSTOM/n.txt"

DTS_DIR="target/linux/mediatek/dts"
IMG="target/linux/mediatek/image/filogic.mk"
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"

FRAG="$(mktemp /tmp/diy_frag.XXXXXX)"
FD="$(mktemp /tmp/diy_f.XXXXXX)"
FN="$(mktemp /tmp/diy_n.XXXXXX)"

# 清 CRLF / UTF-8 BOM
clean_frag() { sed -e 's/\r$//' -e '1s/^\xEF\xBB\xBF//' "$1" > "$2"; }

# 目标文件末尾补换行，防止追加内容粘在最后一行
ensure_eol() { [ -f "$1" ] || return 0; [ -z "$(tail -c 1 "$1")" ] || printf '\n' >> "$1"; }

# 占位骨架检测：没填内容就跳过，避免把 TODO 注释写进固件
is_placeholder() { grep -q 'DIY_TODO_PLACEHOLDER' "$1"; }

echo "===== 应用 custom/（d.txt / f.txt / n.txt，只添加不覆盖）====="
if [ ! -d "$CUSTOM" ]; then
  echo "[diy] ! 未找到 custom/ 目录，跳过全部增补（编译结果与不带 custom 时完全相同）"
else
  [ -f "$F" ] && clean_frag "$F" "$FD" || : > "$FD"
  [ -f "$N" ] && clean_frag "$N" "$FN" || : > "$FN"

  # ---------------- f.txt：追加 Device 定义片段到 filogic.mk 末尾 ----------------
  if [ -s "$FD" ] && ! is_placeholder "$FD"; then
    if [ ! -f "$IMG" ]; then
      echo "[diy] × 找不到 $IMG，f.txt 未应用"
    elif grep -qF '### >>> custom/f.txt' "$IMG"; then
      echo "[diy] - f.txt 已追加过，跳过（幂等）"
    else
      ensure_eol "$IMG"
      { printf '%s\n' '### >>> custom/f.txt'; cat "$FD"; printf '%s\n' '### <<< custom/f.txt'; } >> "$IMG"
      echo "[diy] ✓ f.txt 内容追加到 $IMG 末尾（原文件未改动）"
    fi
  else
    echo "[diy] - 跳过 f.txt（未放置或仍是占位骨架）"
  fi

  # ---------------- d.txt：写入/追加到 <名字>.dts ----------------
  # 文件名优先取 d.txt 首行的 "// FILE: xxx.dts"；
  # 否则从 f.txt 的 "DEVICE_DTS := xxx" 自动推导（无需用户额外提供名字）。
  if [ -s "$D" ]; then
    clean_frag "$D" "$FRAG"
    if is_placeholder "$FRAG"; then
      echo "[diy] - 跳过 d.txt（仍是占位骨架，请填入 dts 内容）"
    else
      name=$(sed -n '1s|^//[[:space:]]*FILE:[[:space:]]*\([^[:space:]]*\).*|\1|p' "$FRAG")
      if [ -n "$name" ]; then
        # 首行是 FILE: 指令，写目标文件时不带入这一行
        sed '1d' "$FRAG" > "$FRAG.body"
      else
        name=$(grep -m1 -E '^[[:space:]]*DEVICE_DTS[[:space:]]*[:+?]?=' "$FD" | \
               sed -E 's|^[^=]*=[[:space:]]*||; s|[[:space:]].*$||; s|^.*/||')
        cp "$FRAG" "$FRAG.body"
      fi
      case "$name" in
        *.dts|*.dtsi) ;;
        '') : ;;
        *) name="$name.dts" ;;
      esac
      if [ -z "$name" ] || [ "$name" = ".dts" ]; then
        echo "[diy] × 无法确定 dts 文件名：请在 d.txt 首行写 \"// FILE: xxx.dts\"，"
        echo "       或在 f.txt 里写 \"DEVICE_DTS := xxx\"；d.txt 未应用"
      else
        mkdir -p "$DTS_DIR"
        DEST="$DTS_DIR/$name"
        if grep -qF '// >>> custom/d.txt' "$DEST" 2>/dev/null; then
          echo "[diy] - d.txt 已写入过 $DEST，跳过（幂等）"
        else
          if [ -f "$DEST" ]; then
            ensure_eol "$DEST"
            { printf '%s\n' '// >>> custom/d.txt'; cat "$FRAG.body"; printf '%s\n' '// <<< custom/d.txt'; } >> "$DEST"
            echo "[diy] ✓ d.txt 内容追加到已有 $DEST 末尾（原内容未改动）"
          else
            { printf '%s\n' '// >>> custom/d.txt'; cat "$FRAG.body"; printf '%s\n' '// <<< custom/d.txt'; } > "$DEST"
            echo "[diy] ✓ d.txt 内容新建为 $DEST"
          fi
        fi
      fi
    fi
  else
    echo "[diy] - 跳过 d.txt（未放置）"
  fi

  # ---------------- n.txt：插入到 02_network 的 case $board in 之后 ----------------
  # 上游文件末尾是 board_config_flush / exit 0，追加到末尾不会执行，
  # 所以必须插到第一个 case 的下一行；原有分支一行不删。
  if [ -s "$FN" ] && ! is_placeholder "$FN"; then
    if [ ! -f "$NET" ]; then
      echo "[diy] × 找不到 $NET，n.txt 未应用"
    elif grep -qF '# >>> custom/n.txt' "$NET"; then
      echo "[diy] - n.txt 已插入过，跳过（幂等）"
    else
      if grep -qE '(^#!/|^[[:space:]]*esac|board_config_update|^[[:space:]]*exit 0|^[[:space:]]*case \$board in)' "$FN"; then
        echo "[diy] ! 警告：n.txt 疑似含完整脚本结构；这里只应放 case 分支，请检查"
      fi
      awk -v frag="$FN" '
        BEGIN { done = 0 }
        {
          print
          if (!done && $0 ~ /^[[:space:]]*case \$board in[[:space:]]*$/) {
            print "\t# >>> custom/n.txt"
            while ((getline line < frag) > 0) print line
            close(frag)
            print "\t# <<< custom/n.txt"
            done = 1
          }
        }
        END { if (!done) exit 3 }
      ' "$NET" > "$NET.tmp"
      if [ $? -eq 0 ]; then
        mv "$NET.tmp" "$NET"
        echo "[diy] ✓ n.txt 内容插入到 $NET 的 case \$board in 之后（原文件未改动）"
      else
        rm -f "$NET.tmp"
        echo "[diy] × 未找到 case \$board in 锚点，n.txt 未应用"
      fi
    fi
  else
    echo "[diy] - 跳过 n.txt（未放置或仍是占位骨架）"
  fi

  echo "[diy] ===== custom/ 增补结束（上游文件未发生覆盖）====="
fi
rm -f "$FRAG" "$FRAG.body" "$FD" "$FN"
echo

CFG="${GITHUB_WORKSPACE}/.config"
JS="package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js"
UCD="package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc"
INIT="package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc"
MK="package/mtk/applications/luci-app-turboacc-mtk/Makefile"
RPCD="package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc"
FWCFG="package/network/config/firewall/files/firewall.config"
LIBMK="package/libs/libnftnl/Makefile"
HACK="target/linux/generic/hack-6.6"

# ---------------- 1/4 .config：撤掉独立模块，bind_rate 一个字都不碰 ----------------
# sonic 把 fullcone 表达式编进内核自带的 nft_masq.ko，不再需要
# kmod-nft-fullcone；若留着 =y，会与 986 注册的同名 expr type 抢注册。
if [ -f "$CFG" ]; then
  sed -i '/^CONFIG_\(PACKAGE\|DEFAULT\)_kmod-nft-fullcone=/d' "$CFG"
  sed -i '/^# CONFIG_PACKAGE_kmod-nft-fullcone is not set$/d' "$CFG"
  echo '# CONFIG_PACKAGE_kmod-nft-fullcone is not set' >> "$CFG"
  sed -i 's|^CONFIG_PACKAGE_kmod-ipt-fullconenat=y|# CONFIG_PACKAGE_kmod-ipt-fullconenat is not set|' "$CFG"
  sed -i 's|^CONFIG_DEFAULT_kmod-ipt-fullconenat=y|# CONFIG_DEFAULT_kmod-ipt-fullconenat is not set|' "$CFG"
  echo "[diy] ✓ .config: kmod-nft-fullcone 已撤掉 / kmod-ipt-fullconenat 已关闭"
  echo "[diy] ✓ bind_rate 未写入 .config，UCI 默认 30 保持不变"
else
  echo "[diy] ! 找不到 $CFG（workflow 步骤 6 才复制），靠 Makefile 依赖与 defconfig 兜底"
fi

# ---------------- 2/4 移除旧 fullcone 实现（3 个文件）----------------
# 682 = BCM-NAT sysctl/helper；旧 fw4 补丁 = kmod-nft-fullcone 那套规则；
# fullconenat.patch = fw3 的 xt_FULLCONENAT 集成。三者都不能与 sonic 共存。
rm -f "target/linux/generic/pending-6.6/682-add-bcm-fullconenat-support.patch"
rm -f "package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
rm -f "package/network/config/firewall/patches/fullconenat.patch"
echo "[diy] ✓ 旧 682 / fw4 / fw3 fullcone 实现已移除"
# 注意：保留 firewall4/patches/002-forbid-using-flow-offload.patch（不冲突）；
#       fullconenat-nft/ 与 fullconenat/ 包源码留在树里但不被选中，无需删除。

# ---------------- 3/4 写入 sonic 官方补丁（10 个，全部内联）----------------
mkdir -p "$HACK" \
  "package/network/utils/iptables/patches" \
  "package/libs/libnftnl/patches" \
  "package/network/utils/nftables/patches" \
  "package/network/config/firewall/patches" \
  "package/network/config/firewall4/patches"

echo "[diy]   -> target/linux/generic/hack-6.6/984-add-sonic-fullcone-support.patch"
cat > "target/linux/generic/hack-6.6/984-add-sonic-fullcone-support.patch" <<'__SONIC_EOF_0__'
From: Akhilesh Samineni <akhilesh.samineni@broadcom.com>
Date: Mon, 6 Nov 2023 11:55:58 -0800
Subject: [PATCH] Support fullcone NAT

Forward-port of SONiC fullcone NAT patch to OpenWrt kernels (6.6/6.12/6.18).
Original: https://github.com/sonic-net/sonic-linux-kernel/blob/master/patches-sonic/Support-for-fullcone-nat.patch

Changes done in the kernel to ensure 3-tuple uniqueness of the conntrack
entries for the fullcone nat functionality.

*   Hashlist is maintained for the 3-tuple unique keys (Protocol/Source
    IP/Port) for all the conntrack entries.
*   When NAT table rules are created with the fullcone option, the
    SNAT/POSTROUTING stage ensures the ports from the pool are picked up in
    such a way that the 3-tuple is uniquely assigned.
*   In the DNAT/POSTROUTING stage, the fullcone behavior is ensured by
    checking and reusing the 3-tuple for the Source IP/Port in the
    original direction.
*   When the pool is exhausted of the 3-tuple assignments, the packets are
    dropped, else, they will be going out of the router they being 5-tuple
    unique (which is not intended).

Signed-off-by: Akhilesh Samineni <akhilesh.samineni@broadcom.com>
[turboacc: adapted to 6.6+ unified nf_nat_l4proto_unique_tuple]
[openwrt-sonic-fullcone: with the fixes submitted to SONiC upstream:
 - find_appropriate_dst() resets dst.dir after nf_ct_invert_tuple()
   https://github.com/sonic-net/sonic-linux-kernel/pull/649
 - nf_nat_by_manip_src gets locks of its own
   https://github.com/sonic-net/sonic-linux-kernel/pull/653]
---
 include/net/netfilter/nf_conntrack.h  |   3 +
 include/uapi/linux/netfilter/nf_nat.h |   3 +-
 net/netfilter/nf_nat_core.c           | 216 ++++++++++++++++++++---
 3 files changed, 190 insertions(+), 32 deletions(-)

--- a/include/net/netfilter/nf_conntrack.h
+++ b/include/net/netfilter/nf_conntrack.h
@@ -103,6 +103,9 @@ struct nf_conn {

 #if IS_ENABLED(CONFIG_NF_NAT)
 	struct hlist_node	nat_bysource;
+
+	/* To optionally ensure 3-tuple uniqueness on the translated source */
+	struct hlist_node	nat_by_manip_src;
 #endif
 	/* all members below initialized via memset */
 	struct { } __nfct_init_offset;
--- a/include/uapi/linux/netfilter/nf_nat.h
+++ b/include/uapi/linux/netfilter/nf_nat.h
@@ -12,6 +12,7 @@
 #define NF_NAT_RANGE_PROTO_RANDOM_FULLY		(1 << 4)
 #define NF_NAT_RANGE_PROTO_OFFSET		(1 << 5)
 #define NF_NAT_RANGE_NETMAP			(1 << 6)
+#define NF_NAT_RANGE_FULLCONE			(1 << 10)

 #define NF_NAT_RANGE_PROTO_RANDOM_ALL		\
 	(NF_NAT_RANGE_PROTO_RANDOM | NF_NAT_RANGE_PROTO_RANDOM_FULLY)
@@ -20,7 +21,7 @@
 	(NF_NAT_RANGE_MAP_IPS | NF_NAT_RANGE_PROTO_SPECIFIED |	\
 	 NF_NAT_RANGE_PROTO_RANDOM | NF_NAT_RANGE_PERSISTENT |	\
 	 NF_NAT_RANGE_PROTO_RANDOM_FULLY | NF_NAT_RANGE_PROTO_OFFSET | \
-	 NF_NAT_RANGE_NETMAP)
+	 NF_NAT_RANGE_NETMAP | NF_NAT_RANGE_FULLCONE)

 struct nf_nat_ipv4_range {
 	unsigned int			flags;
--- a/net/netfilter/nf_nat_core.c
+++ b/net/netfilter/nf_nat_core.c
@@ -33,6 +33,12 @@ static DEFINE_MUTEX(nf_nat_proto_mutex);
 static unsigned int nat_net_id __read_mostly;

 static struct hlist_head *nf_nat_bysource __read_mostly;
+static struct hlist_head *nf_nat_by_manip_src __read_mostly;
+/* nf_nat_by_manip_src is hashed by the translated source, so its buckets
+ * need locks of their own: the nf_nat_locks of the original source do not
+ * cover them.
+ */
+static spinlock_t nf_nat_manip_src_locks[CONNTRACK_LOCKS];
 static unsigned int nf_nat_htable_size __read_mostly;
 static siphash_aligned_key_t nf_nat_hash_rnd;

@@ -180,6 +186,49 @@ hash_by_src(const struct net *net,
 	return reciprocal_scale(hash, nf_nat_htable_size);
 }

+static inline int
+same_reply_dst(const struct nf_conn *ct,
+	       const struct nf_conntrack_tuple *tuple)
+{
+	const struct nf_conntrack_tuple *t;
+
+	t = &ct->tuplehash[IP_CT_DIR_REPLY].tuple;
+	return (t->dst.protonum == tuple->dst.protonum &&
+		nf_inet_addr_cmp(&t->dst.u3, &tuple->dst.u3) &&
+		t->dst.u.all == tuple->dst.u.all);
+}
+
+/* Is this 3-tuple already taken? (not by us) */
+static int
+nf_nat_used_3_tuple(const struct nf_conntrack_tuple *tuple,
+		    const struct nf_conn *ignored_conntrack,
+		    enum nf_nat_manip_type maniptype)
+{
+	const struct nf_conn *ct;
+	const struct nf_conntrack_zone *zone;
+	unsigned int h;
+	struct net *net = nf_ct_net(ignored_conntrack);
+
+	/* 3-tuple uniqueness is required for translated source only */
+	if (maniptype != NF_NAT_MANIP_SRC)
+		return 0;
+
+	zone = nf_ct_zone(ignored_conntrack);
+
+	/* The tuple passed here is the inverted reply (with translated source) */
+	h = hash_by_src(net, zone, tuple);
+	hlist_for_each_entry_rcu(ct, &nf_nat_by_manip_src[h], nat_by_manip_src) {
+		struct nf_conntrack_tuple reply;
+		nf_ct_invert_tuple(&reply, tuple);
+		/* Compare against the destination in the reply */
+		if (same_reply_dst(ct, &reply) &&
+		    net_eq(net, nf_ct_net(ct)) &&
+		    nf_ct_zone_equal(ct, zone, IP_CT_DIR_ORIGINAL))
+			return 1;
+	}
+	return 0;
+}
+
 /**
  * nf_nat_used_tuple - check if proposed nat tuple clashes with existing entry
  * @tuple: proposed NAT binding
@@ -298,6 +347,38 @@ find_appropriate_src(struct net *net,
 	return 0;
 }

+/* Only called for DST manip */
+static int
+find_appropriate_dst(struct net *net,
+		     const struct nf_conntrack_zone *zone,
+		     const struct nf_conntrack_tuple *tuple,
+		     struct nf_conntrack_tuple *result)
+{
+	struct nf_conntrack_tuple reply;
+	unsigned int h;
+	const struct nf_conn *ct;
+
+	nf_ct_invert_tuple(&reply, tuple);
+	h = hash_by_src(net, zone, &reply);
+
+	hlist_for_each_entry_rcu(ct, &nf_nat_by_manip_src[h], nat_by_manip_src) {
+		if (same_reply_dst(ct, tuple) &&
+		    net_eq(net, nf_ct_net(ct)) &&
+		    nf_ct_zone_equal(ct, zone, IP_CT_DIR_REPLY)) {
+			/* Copy destination part from original tuple. */
+			nf_ct_invert_tuple(result,
+					   &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple);
+			result->src = tuple->src;
+			/* nf_ct_invert_tuple() set dir to REPLY, but result
+			 * is an original-direction tuple.
+			 */
+			result->dst.dir = IP_CT_DIR_ORIGINAL;
+			return 1;
+		}
+	}
+	return 0;
+}
+
 /* For [FUTURE] fragmentation handling, we want the least-used
  * src-ip/dst-ip/proto triple.  Fairness doesn't come into it.  Thus
  * if the range specifies 1.2.3.4 ports 10000-10005 and 1.2.3.5 ports
@@ -377,10 +458,10 @@ find_best_ips_proto(const struct nf_conntrack_zone *zone,
  *
  * Per-protocol part of tuple is initialized to the incoming packet.
  */
-static void nf_nat_l4proto_unique_tuple(struct nf_conntrack_tuple *tuple,
-					const struct nf_nat_range2 *range,
-					enum nf_nat_manip_type maniptype,
-					const struct nf_conn *ct)
+static int nf_nat_l4proto_unique_tuple(struct nf_conntrack_tuple *tuple,
+				       const struct nf_nat_range2 *range,
+				       enum nf_nat_manip_type maniptype,
+				       const struct nf_conn *ct)
 {
 	unsigned int range_size, min, max, i, attempts;
 	__be16 *keyptr;
@@ -406,7 +487,7 @@ static void nf_nat_l4proto_unique_tuple(struct nf_conntrack_tuple *tuple,
 		/* If there is no master conntrack we are not PPTP,
 		   do not change tuples */
 		if (!ct->master)
-			return;
+			return 1;

 		if (maniptype == NF_NAT_MANIP_SRC)
 			keyptr = &tuple->src.u.gre.key;
@@ -434,14 +515,14 @@ static void nf_nat_l4proto_unique_tuple(struct nf_conntrack_tuple *tuple,

 		break;
 	default:
-		return;
+		return 0;
 	}

 	/* If no range specified... */
 	if (!(range->flags & NF_NAT_RANGE_PROTO_SPECIFIED)) {
 		/* If it's dst rewrite, can't change port */
 		if (maniptype == NF_NAT_MANIP_DST)
-			return;
+			return 0;

 		if (ntohs(*keyptr) < 1024) {
 			/* Loose convention: >> 512 is credential passing */
@@ -483,12 +564,19 @@ static void nf_nat_l4proto_unique_tuple(struct nf_conntrack_tuple *tuple,
 another_round:
 	for (i = 0; i < attempts; i++, off++) {
 		*keyptr = htons(min + off % range_size);
-		if (!nf_nat_used_tuple_harder(tuple, ct, attempts - i))
-			return;
+
+		if ((range->flags & NF_NAT_RANGE_FULLCONE) &&
+		    (maniptype == NF_NAT_MANIP_SRC)) {
+			if (!nf_nat_used_3_tuple(tuple, ct, maniptype))
+				return 1;
+		} else {
+			if (!nf_nat_used_tuple_harder(tuple, ct, attempts - i))
+				return 1;
+		}
 	}

 	if (attempts >= range_size || attempts < 16)
-		return;
+		return 0;
 	attempts /= 2;
 	off = get_random_u16();
 	goto another_round;
@@ -497,10 +585,15 @@ static void nf_nat_l4proto_unique_tuple(struct nf_conntrack_tuple *tuple,
 /* Manipulate the tuple into the range given. For NF_INET_POST_ROUTING,
  * we change the source to map into the range. For NF_INET_PRE_ROUTING
  * and NF_INET_LOCAL_OUT, we change the destination to map into the
- * range. It might not be possible to get a unique tuple, but we try.
+ * range. It might not be possible to get a unique 5-tuple, but we try.
  * At worst (or if we race), we will end up with a final duplicate in
- * __nf_conntrack_confirm and drop the packet. */
-static void
+ * __nf_conntrack_confirm and drop the packet.
+ * If the range is of type fullcone, if we end up with a 3-tuple
+ * duplicate, we do not wait till the packet reaches the
+ * nf_conntrack_confirm to drop the packet. Instead return the packet
+ * to be dropped at this stage.
+ */
+static int
 get_unique_tuple(struct nf_conntrack_tuple *tuple,
 		 const struct nf_conntrack_tuple *orig_tuple,
 		 const struct nf_nat_range2 *range,
@@ -508,8 +601,11 @@ get_unique_tuple(struct nf_conntrack_tuple *tuple,
 		 enum nf_nat_manip_type maniptype)
 {
 	const struct nf_conntrack_zone *zone;
+	struct nf_nat_range2 nat_range;
 	struct net *net = nf_ct_net(ct);

+	memcpy(&nat_range, range, sizeof(struct nf_nat_range2));
+
 	zone = nf_ct_zone(ct);

 	/* 1) If this srcip/proto/src-proto-part is currently mapped,
@@ -521,46 +617,75 @@ get_unique_tuple(struct nf_conntrack_tuple *tuple,
 	 * manips not an issue.
 	 */
 	if (maniptype == NF_NAT_MANIP_SRC &&
-	    !(range->flags & NF_NAT_RANGE_PROTO_RANDOM_ALL)) {
+	    !(nat_range.flags & NF_NAT_RANGE_PROTO_RANDOM_ALL)) {
 		/* try the original tuple first */
-		if (nf_in_range(orig_tuple, range)) {
+		if (nf_in_range(orig_tuple, &nat_range)) {
 			if (!nf_nat_used_tuple_new(orig_tuple, ct)) {
 				*tuple = *orig_tuple;
-				return;
+				goto out;
 			}
 		} else if (find_appropriate_src(net, zone,
-						orig_tuple, tuple, range)) {
+						orig_tuple, tuple, &nat_range)) {
 			pr_debug("get_unique_tuple: Found current src map\n");
 			if (!nf_nat_used_tuple(tuple, ct))
-				return;
+				goto out;
+		}
+	}
+
+	if (maniptype == NF_NAT_MANIP_DST) {
+		if (nat_range.flags & NF_NAT_RANGE_FULLCONE) {
+			/* Destination IP range does not apply when fullcone flag is set. */
+			nat_range.min_addr = nat_range.max_addr = orig_tuple->dst.u3;
+			nat_range.min_proto.all = nat_range.max_proto.all = 0;
+
+			/* If this dstip/proto/dst-proto-part is mapped currently
+			 * as a translated source for a given tuple, use that
+			 */
+			if (find_appropriate_dst(net, zone,
+						 orig_tuple, tuple)) {
+				if (!nf_nat_used_tuple(tuple, ct))
+					goto out;
+			} else {
+				/* If not mapped, proceed with the original tuple */
+				*tuple = *orig_tuple;
+				goto out;
+			}
 		}
 	}

 	/* 2) Select the least-used IP/proto combination in the given range */
 	*tuple = *orig_tuple;
-	find_best_ips_proto(zone, tuple, range, ct, maniptype);
+	find_best_ips_proto(zone, tuple, &nat_range, ct, maniptype);

 	/* 3) The per-protocol part of the manip is made to map into
 	 * the range to make a unique tuple.
 	 */

 	/* Only bother mapping if it's not already in range and unique */
-	if (!(range->flags & NF_NAT_RANGE_PROTO_RANDOM_ALL)) {
-		if (range->flags & NF_NAT_RANGE_PROTO_SPECIFIED) {
-			if (!(range->flags & NF_NAT_RANGE_PROTO_OFFSET) &&
+	if (!(nat_range.flags & NF_NAT_RANGE_PROTO_RANDOM_ALL)) {
+		if (nat_range.flags & NF_NAT_RANGE_PROTO_SPECIFIED) {
+			if (!(nat_range.flags & NF_NAT_RANGE_PROTO_OFFSET) &&
 			    l4proto_in_range(tuple, maniptype,
-					     &range->min_proto,
-					     &range->max_proto) &&
-			    (range->min_proto.all == range->max_proto.all ||
-			     !nf_nat_used_tuple(tuple, ct)))
-				return;
+					     &(nat_range.min_proto),
+					     &(nat_range.max_proto))) {
+				if (nat_range.flags & NF_NAT_RANGE_FULLCONE) {
+					if (!nf_nat_used_3_tuple(tuple, ct, maniptype))
+						goto out;
+				} else {
+					if ((nat_range.min_proto.all == nat_range.max_proto.all) ||
+					    !nf_nat_used_tuple(tuple, ct))
+						goto out;
+				}
+			}
 		} else if (!nf_nat_used_tuple(tuple, ct)) {
-			return;
+			goto out;
 		}
 	}

 	/* Last chance: get protocol to try to obtain unique tuple. */
-	nf_nat_l4proto_unique_tuple(tuple, range, maniptype, ct);
+	return nf_nat_l4proto_unique_tuple(tuple, &nat_range, maniptype, ct);
+out:
+	return 1;
 }

 struct nf_conn_nat *nf_ct_nat_ext_add(struct nf_conn *ct)
@@ -602,7 +727,9 @@ nf_nat_setup_info(struct nf_conn *ct,
 	nf_ct_invert_tuple(&curr_tuple,
 			   &ct->tuplehash[IP_CT_DIR_REPLY].tuple);

-	get_unique_tuple(&new_tuple, &curr_tuple, range, ct, maniptype);
+	if (!get_unique_tuple(&new_tuple, &curr_tuple, range, ct, maniptype)) {
+		return NF_DROP;
+	}

 	if (!nf_ct_tuple_equal(&new_tuple, &curr_tuple)) {
 		struct nf_conntrack_tuple reply;
@@ -624,12 +751,20 @@ nf_nat_setup_info(struct nf_conn *ct,

 	if (maniptype == NF_NAT_MANIP_SRC) {
 		unsigned int srchash;
+		unsigned int manip_src_hash;
 		spinlock_t *lock;

+		manip_src_hash = hash_by_src(net, nf_ct_zone(ct), &new_tuple);
+		lock = &nf_nat_manip_src_locks[manip_src_hash % CONNTRACK_LOCKS];
+		spin_lock_bh(lock);
+		hlist_add_head_rcu(&ct->nat_by_manip_src,
+				   &nf_nat_by_manip_src[manip_src_hash]);
+		spin_unlock_bh(lock);
+
 		srchash = hash_by_src(net, nf_ct_zone(ct),
 				      &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple);
 		lock = &nf_nat_locks[srchash % CONNTRACK_LOCKS];
 		spin_lock_bh(lock);
 		hlist_add_head_rcu(&ct->nat_bysource,
 				   &nf_nat_bysource[srchash]);
 		spin_unlock_bh(lock);
@@ -803,8 +938,16 @@ static int nf_nat_proto_remove(struct nf_conn *i, void *data)

 static void nf_nat_cleanup_conntrack(struct nf_conn *ct)
 {
+	struct nf_conntrack_tuple tuple;
 	unsigned int h;

+	/* nat_by_manip_src was hashed by the translated source */
+	nf_ct_invert_tuple(&tuple, &ct->tuplehash[IP_CT_DIR_REPLY].tuple);
+	h = hash_by_src(nf_ct_net(ct), nf_ct_zone(ct), &tuple);
+	spin_lock_bh(&nf_nat_manip_src_locks[h % CONNTRACK_LOCKS]);
+	hlist_del_rcu(&ct->nat_by_manip_src);
+	spin_unlock_bh(&nf_nat_manip_src_locks[h % CONNTRACK_LOCKS]);
+
 	h = hash_by_src(nf_ct_net(ct), nf_ct_zone(ct), &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple);
 	spin_lock_bh(&nf_nat_locks[h % CONNTRACK_LOCKS]);
 	hlist_del_rcu(&ct->nat_bysource);
@@ -1138,12 +1281,21 @@ static int __init nf_nat_init(void)
 	if (!nf_nat_bysource)
 		return -ENOMEM;

+	nf_nat_by_manip_src = nf_ct_alloc_hashtable(&nf_nat_htable_size, 0);
+	if (!nf_nat_by_manip_src) {
+		kvfree(nf_nat_bysource);
+		return -ENOMEM;
+	}
+
-	for (i = 0; i < CONNTRACK_LOCKS; i++)
+	for (i = 0; i < CONNTRACK_LOCKS; i++) {
 		spin_lock_init(&nf_nat_locks[i]);
+		spin_lock_init(&nf_nat_manip_src_locks[i]);
+	}

 	ret = register_pernet_subsys(&nat_net_ops);
 	if (ret < 0) {
 		kvfree(nf_nat_bysource);
+		kvfree(nf_nat_by_manip_src);
 		return ret;
 	}

@@ -1160,4 +1312,5 @@ static int __init nf_nat_init(void)
 		unregister_pernet_subsys(&nat_net_ops);
 		kvfree(nf_nat_bysource);
+		kvfree(nf_nat_by_manip_src);
 	}

@@ -1177,2 +1330,3 @@ static void __exit nf_nat_cleanup(void)
 	kvfree(nf_nat_bysource);
+	kvfree(nf_nat_by_manip_src);
 	unregister_pernet_subsys(&nat_net_ops);
__SONIC_EOF_0__
echo "[diy]   -> target/linux/generic/hack-6.6/985-add-sonic-fullcone-to-ipt.patch"
cat > "target/linux/generic/hack-6.6/985-add-sonic-fullcone-to-ipt.patch" <<'__SONIC_EOF_1__'
From: openwrt-sonic-fullcone contributors
Date: Wed, 9 Apr 2026 00:00:00 +0000
Subject: [PATCH] netfilter: xt_MASQUERADE: add FULLCONE target for iptables

Register a new iptables target "FULLCONE" alongside the existing
"MASQUERADE" target inside the same xt_MASQUERADE.ko module. Unlike
MASQUERADE which only allows POSTROUTING, FULLCONE allows both
PREROUTING and POSTROUTING hooks:

  - POSTROUTING: masquerade + NF_NAT_RANGE_FULLCONE flag
                 (sets up 3-tuple unique mapping via 984 patch)
  - PREROUTING:  reverse lookup via find_appropriate_dst()
                 (provides EIF — endpoint-independent filtering)

This is the iptables equivalent of the fw4 nft_fullcone expression.
No new kernel module is needed — FULLCONE registers inside the
existing xt_MASQUERADE.ko which is already loaded when fw3 uses NAT.

Usage:
  iptables -t nat -A POSTROUTING -o wan -j FULLCONE
  iptables -t nat -A PREROUTING  -i wan -j FULLCONE

Requires 984-add-sonic-fullcone-support.patch for the kernel-side
NF_NAT_RANGE_FULLCONE flag and 3-tuple hash table.

The module aliases ipt_FULLCONE and ip6t_FULLCONE let iptables load
xt_MASQUERADE.ko on demand for the new target. The IPv4 target shares
masquerade_tg_check(), which also rejects an address range the target
would ignore.
---
 net/netfilter/xt_MASQUERADE.c | 92 ++++++++++++++++++++++++++++++++++++-
 1 file changed, 91 insertions(+), 1 deletion(-)

--- a/net/netfilter/xt_MASQUERADE.c
+++ b/net/netfilter/xt_MASQUERADE.c
@@ -9,8 +9,10 @@
 #define pr_fmt(fmt) KBUILD_MODNAME ": " fmt
 #include <linux/module.h>
 #include <linux/netfilter/x_tables.h>
+#include <net/netfilter/nf_conntrack.h>
 #include <net/netfilter/nf_nat.h>
 #include <net/netfilter/nf_nat_masquerade.h>
+#include <uapi/linux/netfilter/nf_nat.h>

 MODULE_LICENSE("GPL");
 MODULE_AUTHOR("Netfilter Core Team <coreteam@netfilter.org>");
@@ -72,6 +74,66 @@ static int masquerade_tg6_checkentry(con
 }
 #endif

+/* SONiC fullcone target: allows both PRE- and POST-routing hooks.
+ * POSTROUTING: regular masquerade with NF_NAT_RANGE_FULLCONE flag
+ *              (3-tuple unique mapping via 984 patch).
+ * PREROUTING:  reverse lookup via find_appropriate_dst() in
+ *              nf_nat_setup_info() with NF_NAT_MANIP_DST.
+ */
+static unsigned int
+fullcone_tg(struct sk_buff *skb, const struct xt_action_param *par)
+{
+	const struct nf_nat_ipv4_multi_range_compat *mr = par->targinfo;
+	struct nf_nat_range2 range;
+	struct nf_conn *ct;
+	enum ip_conntrack_info ctinfo;
+
+	memset(&range, 0, sizeof(range));
+	range.flags      = mr->range[0].flags | NF_NAT_RANGE_FULLCONE;
+	range.min_proto  = mr->range[0].min;
+	range.max_proto  = mr->range[0].max;
+
+	if (xt_hooknum(par) == NF_INET_POST_ROUTING)
+		return nf_nat_masquerade_ipv4(skb, xt_hooknum(par), &range,
+					      xt_out(par));
+
+	/* PREROUTING: reverse mapping for EIF */
+	ct = nf_ct_get(skb, &ctinfo);
+	if (!ct || (ctinfo != IP_CT_NEW && ctinfo != IP_CT_RELATED &&
+		    ctinfo != IP_CT_RELATED_REPLY))
+		return NF_ACCEPT;
+
+	return nf_nat_setup_info(ct, &range, NF_NAT_MANIP_DST);
+}
+
+#if IS_ENABLED(CONFIG_IPV6)
+static unsigned int
+fullcone_tg6(struct sk_buff *skb, const struct xt_action_param *par)
+{
+	const struct nf_nat_range *orig = par->targinfo;
+	struct nf_nat_range2 range;
+	struct nf_conn *ct;
+	enum ip_conntrack_info ctinfo;
+
+	memset(&range, 0, sizeof(range));
+	range.flags      = orig->flags | NF_NAT_RANGE_FULLCONE;
+	range.min_addr   = orig->min_addr;
+	range.max_addr   = orig->max_addr;
+	range.min_proto  = orig->min_proto;
+	range.max_proto  = orig->max_proto;
+
+	if (xt_hooknum(par) == NF_INET_POST_ROUTING)
+		return nf_nat_masquerade_ipv6(skb, &range, xt_out(par));
+
+	ct = nf_ct_get(skb, &ctinfo);
+	if (!ct || (ctinfo != IP_CT_NEW && ctinfo != IP_CT_RELATED &&
+		    ctinfo != IP_CT_RELATED_REPLY))
+		return NF_ACCEPT;
+
+	return nf_nat_setup_info(ct, &range, NF_NAT_MANIP_DST);
+}
+#endif
+
 static struct xt_target masquerade_tg_reg[] __read_mostly = {
 	{
 #if IS_ENABLED(CONFIG_IPV6)
@@ -95,7 +157,33 @@ static struct xt_target masquerade_tg_re
 		.checkentry	= masquerade_tg_check,
 		.destroy	= masquerade_tg_destroy,
 		.me		= THIS_MODULE,
-	}
+	},
+	{
+		.name		= "FULLCONE",
+		.family		= NFPROTO_IPV4,
+		.target		= fullcone_tg,
+		.targetsize	= sizeof(struct nf_nat_ipv4_multi_range_compat),
+		.table		= "nat",
+		.hooks		= (1 << NF_INET_PRE_ROUTING) |
+				  (1 << NF_INET_POST_ROUTING),
+		.checkentry	= masquerade_tg_check,
+		.destroy	= masquerade_tg_destroy,
+		.me		= THIS_MODULE,
+	},
+#if IS_ENABLED(CONFIG_IPV6)
+	{
+		.name		= "FULLCONE",
+		.family		= NFPROTO_IPV6,
+		.target		= fullcone_tg6,
+		.targetsize	= sizeof(struct nf_nat_range),
+		.table		= "nat",
+		.hooks		= (1 << NF_INET_PRE_ROUTING) |
+				  (1 << NF_INET_POST_ROUTING),
+		.checkentry	= masquerade_tg6_checkentry,
+		.destroy	= masquerade_tg_destroy,
+		.me		= THIS_MODULE,
+	},
+#endif
 };

 static int __init masquerade_tg_init(void)
@@ -127,5 +215,7 @@ module_init(masquerade_tg_init);
 module_exit(masquerade_tg_exit);
 #if IS_ENABLED(CONFIG_IPV6)
 MODULE_ALIAS("ip6t_MASQUERADE");
+MODULE_ALIAS("ip6t_FULLCONE");
 #endif
 MODULE_ALIAS("ipt_MASQUERADE");
+MODULE_ALIAS("ipt_FULLCONE");
__SONIC_EOF_1__
echo "[diy]   -> target/linux/generic/hack-6.6/986-add-sonic-fullcone-to-nft.patch"
cat > "target/linux/generic/hack-6.6/986-add-sonic-fullcone-to-nft.patch" <<'__SONIC_EOF_2__'
From: openwrt-sonic-fullcone contributors
Date: Wed, 9 Apr 2026 00:00:00 +0000
Subject: [PATCH] netfilter: nft_masq: add fullcone expression to masquerade
 module

Add a "fullcone" nftables expression alongside the existing "masq"
expression, compiled into the same nft_masq.ko module. No new kernel
module, no extra Kconfig option, no kmod package needed.

The fullcone expression reuses masq's init/dump functions (attribute
layout is identical), but has its own validate (allows both prerouting
and postrouting hooks) and eval (sets NF_NAT_RANGE_FULLCONE and handles
DNAT reverse mapping on prerouting).

Requires 984-add-sonic-fullcone-support.patch for the kernel-side
NF_NAT_RANGE_FULLCONE flag and 3-tuple hash table.

The .reduce member is set only when the kernel still provides the
register tracking infrastructure. Upstream commit 6b94d081f81d
("netfilter: nf_tables: remove register tracking infrastructure")
dropped nft_expr_ops->reduce and NFT_REDUCE_READONLY, and it has been
backported into the 6.6.y, 6.12.y and 6.18.y stable trees, so a
LINUX_VERSION_CODE test would not work: key off the macro instead.

The expression type is registered for NFPROTO_UNSPEC, so it can be used
in ip, ip6 and inet tables; its init rejects other table families.
---
 net/netfilter/nft_masq.c | 136 ++++++++++++++++++++++++++++++++++++++++
 1 file changed, 136 insertions(+)

--- a/net/netfilter/nft_masq.c
+++ b/net/netfilter/nft_masq.c
@@ -14,6 +14,8 @@
 #include <net/netfilter/nf_tables.h>
 #include <net/netfilter/nf_nat.h>
 #include <net/netfilter/nf_nat_masquerade.h>
+#include <net/netfilter/nf_conntrack.h>
+#include <uapi/linux/netfilter/nf_nat.h>

 struct nft_masq {
 	u32			flags;
@@ -128,6 +130,108 @@ static void nft_masq_eval(const struct n
 	}
 }

+/* SONiC fullcone expression — shares struct/init/dump with masq,
+ * but allows prerouting hook and sets NF_NAT_RANGE_FULLCONE.
+ */
+
+enum nft_fullcone_attributes {
+	NFTA_FULLCONE_UNSPEC,
+	NFTA_FULLCONE_FLAGS,
+	NFTA_FULLCONE_REG_PROTO_MIN,
+	NFTA_FULLCONE_REG_PROTO_MAX,
+	__NFTA_FULLCONE_MAX
+};
+#define NFTA_FULLCONE_MAX	(__NFTA_FULLCONE_MAX - 1)
+
+static const struct nla_policy nft_fullcone_policy[NFTA_FULLCONE_MAX + 1] = {
+	[NFTA_FULLCONE_FLAGS]		=
+		NLA_POLICY_MASK(NLA_BE32, NF_NAT_RANGE_MASK),
+	[NFTA_FULLCONE_REG_PROTO_MIN]	= { .type = NLA_U32 },
+	[NFTA_FULLCONE_REG_PROTO_MAX]	= { .type = NLA_U32 },
+};
+
+/* One expression type serves ip, ip6 and inet NAT tables */
+static int nft_fullcone_init(const struct nft_ctx *ctx,
+			     const struct nft_expr *expr,
+			     const struct nlattr * const tb[])
+{
+	switch (ctx->family) {
+	case NFPROTO_IPV4:
+	case NFPROTO_IPV6:
+	case NFPROTO_INET:
+		return nft_masq_init(ctx, expr, tb);
+	}
+	return -EOPNOTSUPP;
+}
+
+static int nft_fullcone_validate(const struct nft_ctx *ctx,
+				 const struct nft_expr *expr)
+{
+	int err;
+
+	err = nft_chain_validate_dependency(ctx->chain, NFT_CHAIN_T_NAT);
+	if (err < 0)
+		return err;
+
+	return nft_chain_validate_hooks(ctx->chain,
+			(1 << NF_INET_PRE_ROUTING) |
+			(1 << NF_INET_POST_ROUTING));
+}
+
+static void nft_fullcone_eval(const struct nft_expr *expr,
+			      struct nft_regs *regs,
+			      const struct nft_pktinfo *pkt)
+{
+	const struct nft_masq *priv = nft_expr_priv(expr);
+	struct nf_nat_range2 range;
+	enum nf_nat_manip_type mtype = HOOK2MANIP(nft_hook(pkt));
+
+	memset(&range, 0, sizeof(range));
+	range.flags = priv->flags | NF_NAT_RANGE_FULLCONE;
+
+	if (priv->sreg_proto_min) {
+		range.min_proto.all = (__force __be16)
+			nft_reg_load16(&regs->data[priv->sreg_proto_min]);
+		range.max_proto.all = (__force __be16)
+			nft_reg_load16(&regs->data[priv->sreg_proto_max]);
+	}
+
+	if (mtype == NF_NAT_MANIP_SRC) {
+		switch (nft_pf(pkt)) {
+		case NFPROTO_IPV4:
+			regs->verdict.code = nf_nat_masquerade_ipv4(pkt->skb,
+					nft_hook(pkt), &range, nft_out(pkt));
+			break;
+#ifdef CONFIG_NF_TABLES_IPV6
+		case NFPROTO_IPV6:
+			regs->verdict.code = nf_nat_masquerade_ipv6(pkt->skb,
+					&range, nft_out(pkt));
+			break;
+#endif
+		default:
+			break;
+		}
+	} else {
+		struct nf_conn *ct;
+		enum ip_conntrack_info ctinfo;
+
+		ct = nf_ct_get(pkt->skb, &ctinfo);
+		if (!ct || (ctinfo != IP_CT_NEW && ctinfo != IP_CT_RELATED &&
+			    ctinfo != IP_CT_RELATED_REPLY)) {
+			regs->verdict.code = NF_ACCEPT;
+			return;
+		}
+		regs->verdict.code = nf_nat_setup_info(ct, &range,
+						       NF_NAT_MANIP_DST);
+	}
+}
+
+static void
+nft_fullcone_destroy(const struct nft_ctx *ctx, const struct nft_expr *expr)
+{
+	nf_ct_netns_put(ctx->net, ctx->family);
+}
+
 static void
 nft_masq_ipv4_destroy(const struct nft_ctx *ctx, const struct nft_expr *expr)
 {
@@ -228,6 +332,29 @@ static inline void nft_masq_module_exit_
 static inline void nft_masq_module_exit_inet(void) {}
 #endif

+static struct nft_expr_type nft_fullcone_type;
+static const struct nft_expr_ops nft_fullcone_ops = {
+	.type		= &nft_fullcone_type,
+	.size		= NFT_EXPR_SIZE(sizeof(struct nft_masq)),
+	.eval		= nft_fullcone_eval,
+	.init		= nft_fullcone_init,
+	.destroy	= nft_fullcone_destroy,
+	.dump		= nft_masq_dump,
+	.validate	= nft_fullcone_validate,
+#ifdef NFT_REDUCE_READONLY
+	.reduce		= NFT_REDUCE_READONLY,
+#endif
+};
+
+static struct nft_expr_type nft_fullcone_type __read_mostly = {
+	.family		= NFPROTO_UNSPEC,
+	.name		= "fullcone",
+	.ops		= &nft_fullcone_ops,
+	.policy		= nft_fullcone_policy,
+	.maxattr	= NFTA_FULLCONE_MAX,
+	.owner		= THIS_MODULE,
+};
+
 static int __init nft_masq_module_init(void)
 {
 	int ret;
@@ -249,6 +376,13 @@ static int __init nft_masq_module_init(v
 		return ret;
 	}

+	ret = nft_register_expr(&nft_fullcone_type);
+	if (ret < 0) {
+		nf_nat_masquerade_inet_unregister_notifiers();
+		nft_unregister_expr(&nft_masq_ipv4_type);
+		nft_masq_module_exit_inet();
+		nft_masq_module_exit_ipv6();
+	}
 	return ret;
 }

@@ -257,11 +391,13 @@ static void __exit nft_masq_module_exit(
 	nft_masq_module_exit_ipv6();
 	nft_masq_module_exit_inet();
 	nft_unregister_expr(&nft_masq_ipv4_type);
+	nft_unregister_expr(&nft_fullcone_type);
 	nf_nat_masquerade_inet_unregister_notifiers();
 }

 module_init(nft_masq_module_init);
 module_exit(nft_masq_module_exit);
+MODULE_ALIAS_NFT_EXPR("fullcone");

 MODULE_LICENSE("GPL");
 MODULE_AUTHOR("Arturo Borrero Gonzalez <arturo@debian.org>");
__SONIC_EOF_2__
echo "[diy]   -> target/linux/generic/hack-6.6/987-sonic-fullcone-fix-races-and-drops.patch"
cat > "target/linux/generic/hack-6.6/987-sonic-fullcone-fix-races-and-drops.patch" <<'__SONIC_EOF_3__'
From: openwrt-sonic-fullcone contributors
Date: Mon, 3 Nov 2026 00:00:00 +0000
Subject: [PATCH] netfilter: nf_nat: fix races and dropped packets in SONiC
 fullcone NAT

Fixes on top of 984, the SONiC fullcone NAT patch with the fixes
submitted to SONiC. They are not part of the SONiC patch and have not
been submitted there; without this file, 984 builds as it is.

- find_appropriate_dst() walked nf_nat_by_manip_src under RCU only.
  Conntracks are SLAB_TYPESAFE_BY_RCU, so an entry could be freed and
  reused while its tuple was copied, and the packet DNATed to the wrong
  host. Walk the table, and check 3-tuples, under the bucket lock.
- The port search checked the 3-tuple without a lock and the entry was
  added later, so two internal endpoints could take the same translated
  source. The first packets of one internal endpoint, set up on two CPUs
  at once, could also get two translated sources. Check the 3-tuple
  again under the bucket lock and add the entry in the same critical
  section, and set up the fullcone bindings of one internal endpoint one
  at a time.
- Without a port range, fullcone only checked 5-tuple uniqueness, so two
  internal endpoints could share a translated source. fw3 generates its
  UDP-Lite rule without one, since iptables takes no port range for
  UDP-Lite, and hand-written rules can leave it out. Check the 3-tuple
  in that case as well.
- nf_nat_l4proto_unique_tuple() returned 0, which drops the packet, also
  where upstream keeps the tuple: protocols without ports when the rule
  asks for random ports, DNAT without a port range, and an ordinary
  binding whose port search runs out. Only a fullcone binding without a
  free 3-tuple is dropped now.
---
 net/netfilter/nf_nat_core.c | 148 ++++++++++++++++++++++++++++++++------
 1 file changed, 126 insertions(+), 22 deletions(-)

--- a/net/netfilter/nf_nat_core.c
+++ b/net/netfilter/nf_nat_core.c
@@ -42,6 +42,12 @@ static struct hlist_head *nf_nat_by_mani
  * cover them.
  */
 static spinlock_t nf_nat_manip_src_locks[CONNTRACK_LOCKS];
+/* Serializes the fullcone SNAT setup of one internal endpoint. */
+static spinlock_t nf_nat_fullcone_locks[CONNTRACK_LOCKS];
+/* Port searches for a fullcone binding whose translated source was taken
+ * by another binding before it could add its own.
+ */
+#define NF_NAT_FULLCONE_RETRIES	8
 static unsigned int nf_nat_htable_size __read_mostly;
 static siphash_aligned_key_t nf_nat_hash_rnd;
 
@@ -205,8 +211,10 @@ nf_nat_used_3_tuple(const struct nf_conn
 {
 	const struct nf_conn *ct;
 	const struct nf_conntrack_zone *zone;
+	struct nf_conntrack_tuple reply;
 	unsigned int h;
 	struct net *net = nf_ct_net(ignored_conntrack);
+	int used = 0;
 
 	/* 3-tuple uniqueness is required for translated source only */
 	if (maniptype != NF_NAT_MANIP_SRC)
@@ -216,16 +224,19 @@ nf_nat_used_3_tuple(const struct nf_conn
 
 	/* The tuple passed here is the inverted reply (with translated source) */
 	h = hash_by_src(net, zone, tuple);
-	hlist_for_each_entry_rcu(ct, &nf_nat_by_manip_src[h], nat_by_manip_src) {
-		struct nf_conntrack_tuple reply;
-		nf_ct_invert_tuple(&reply, tuple);
+	nf_ct_invert_tuple(&reply, tuple);
+	spin_lock_bh(&nf_nat_manip_src_locks[h % CONNTRACK_LOCKS]);
+	hlist_for_each_entry(ct, &nf_nat_by_manip_src[h], nat_by_manip_src) {
 		/* Compare against the destination in the reply */
 		if (same_reply_dst(ct, &reply) &&
 		    net_eq(net, nf_ct_net(ct)) &&
-		    nf_ct_zone_equal(ct, zone, IP_CT_DIR_ORIGINAL))
-			return 1;
+		    nf_ct_zone_equal(ct, zone, IP_CT_DIR_ORIGINAL)) {
+			used = 1;
+			break;
+		}
 	}
-	return 0;
+	spin_unlock_bh(&nf_nat_manip_src_locks[h % CONNTRACK_LOCKS]);
+	return used;
 }
 
 /**
@@ -510,6 +521,35 @@ same_src(const struct nf_conn *ct,
 		t->src.u.all == tuple->src.u.all);
 }
 
+/* Is the translated source of tuple taken, for a fullcone binding of ct?
+ * It is not when the same internal endpoint already maps to it: ct joins
+ * that mapping, as find_appropriate_src() has it do. Otherwise any other
+ * binding takes it, as in nf_nat_used_3_tuple().
+ * Caller holds the nf_nat_manip_src_locks lock of bucket h.
+ */
+static bool
+nf_nat_3_tuple_taken(const struct nf_conntrack_tuple *tuple,
+		     const struct nf_conn *ct, unsigned int h)
+{
+	const struct nf_conntrack_zone *zone = nf_ct_zone(ct);
+	struct net *net = nf_ct_net(ct);
+	struct nf_conntrack_tuple reply;
+	const struct nf_conn *other;
+	bool taken = false;
+
+	nf_ct_invert_tuple(&reply, tuple);
+	hlist_for_each_entry(other, &nf_nat_by_manip_src[h], nat_by_manip_src) {
+		if (!same_reply_dst(other, &reply) ||
+		    !net_eq(net, nf_ct_net(other)) ||
+		    !nf_ct_zone_equal(other, zone, IP_CT_DIR_ORIGINAL))
+			continue;
+		if (same_src(other, &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple))
+			return false;
+		taken = true;
+	}
+	return taken;
+}
+
 /* Only called for SRC manip */
 static int
 find_appropriate_src(struct net *net,
@@ -547,11 +587,17 @@ find_appropriate_dst(struct net *net,
 	struct nf_conntrack_tuple reply;
 	unsigned int h;
 	const struct nf_conn *ct;
+	int found = 0;
 
 	nf_ct_invert_tuple(&reply, tuple);
 	h = hash_by_src(net, zone, &reply);
 
-	hlist_for_each_entry_rcu(ct, &nf_nat_by_manip_src[h], nat_by_manip_src) {
+	/* Conntracks are SLAB_TYPESAFE_BY_RCU: without the bucket lock an
+	 * entry could be freed and reused while its tuple is copied, and
+	 * the packet sent to some other host.
+	 */
+	spin_lock_bh(&nf_nat_manip_src_locks[h % CONNTRACK_LOCKS]);
+	hlist_for_each_entry(ct, &nf_nat_by_manip_src[h], nat_by_manip_src) {
 		if (same_reply_dst(ct, tuple) &&
 		    net_eq(net, nf_ct_net(ct)) &&
 		    nf_ct_zone_equal(ct, zone, IP_CT_DIR_REPLY)) {
@@ -563,10 +609,12 @@ find_appropriate_dst(struct net *net,
 			 * is an original-direction tuple.
 			 */
 			result->dst.dir = IP_CT_DIR_ORIGINAL;
-			return 1;
+			found = 1;
+			break;
 		}
 	}
-	return 0;
+	spin_unlock_bh(&nf_nat_manip_src_locks[h % CONNTRACK_LOCKS]);
+	return found;
 }
 
 /* For [FUTURE] fragmentation handling, we want the least-used
@@ -703,14 +751,14 @@ static int nf_nat_l4proto_unique_tuple(s
 
 		break;
 	default:
-		return 0;
+		return 1;
 	}
 
 	/* If no range specified... */
 	if (!(range->flags & NF_NAT_RANGE_PROTO_SPECIFIED)) {
 		/* If it's dst rewrite, can't change port */
 		if (maniptype == NF_NAT_MANIP_DST)
-			return 0;
+			return 1;
 
 		if (ntohs(*keyptr) < 1024) {
 			/* Loose convention: >> 512 is credential passing */
@@ -766,8 +814,13 @@ another_round:
 		}
 	}
 
+	/* Only a fullcone binding needs a 3-tuple of its own. Otherwise keep
+	 * the last tuple, as upstream does, and let __nf_conntrack_confirm
+	 * deal with a clash.
+	 */
 	if (attempts >= range_size || attempts < 16)
-		return 0;
+		return !((range->flags & NF_NAT_RANGE_FULLCONE) &&
+			 maniptype == NF_NAT_MANIP_SRC);
 	attempts /= 2;
 	off = get_random_u16();
 	goto another_round;
@@ -868,7 +921,9 @@ get_unique_tuple(struct nf_conntrack_tup
 						goto out;
 				}
 			}
-		} else if (!nf_nat_used_tuple(tuple, ct)) {
+		} else if (!nf_nat_used_tuple(tuple, ct) &&
+			   !((nat_range.flags & NF_NAT_RANGE_FULLCONE) &&
+			     nf_nat_used_3_tuple(tuple, ct, maniptype))) {
 			goto out;
 		}
 	}
@@ -899,6 +954,11 @@ nf_nat_setup_info(struct nf_conn *ct,
 {
 	struct net *net = nf_ct_net(ct);
 	struct nf_conntrack_tuple curr_tuple, new_tuple;
+	bool fullcone = maniptype == NF_NAT_MANIP_SRC &&
+			(range->flags & NF_NAT_RANGE_FULLCONE);
+	spinlock_t *fullcone_lock = NULL, *manip_src_lock = NULL;
+	unsigned int manip_src_hash = 0, retries = 0, ret;
+	struct nf_nat_range2 retry_range;
 
 	/* Can't setup nat info for confirmed ct. */
 	if (nf_ct_is_confirmed(ct))
@@ -918,8 +978,47 @@ nf_nat_setup_info(struct nf_conn *ct,
 	nf_ct_invert_tuple(&curr_tuple,
 			   &ct->tuplehash[IP_CT_DIR_REPLY].tuple);
 
+	/* Set up the fullcone bindings of one internal endpoint one at a
+	 * time, so the second one finds the mapping of the first instead of
+	 * taking a second translated source.
+	 */
+	if (fullcone) {
+		unsigned int h = hash_by_src(net, nf_ct_zone(ct), &curr_tuple);
+
+		fullcone_lock = &nf_nat_fullcone_locks[h % CONNTRACK_LOCKS];
+		spin_lock_bh(fullcone_lock);
+	}
+
+again:
 	if (!get_unique_tuple(&new_tuple, &curr_tuple, range, ct, maniptype)) {
-		return NF_DROP;
+		ret = NF_DROP;
+		goto out;
+	}
+
+	if (maniptype == NF_NAT_MANIP_SRC) {
+		manip_src_hash = hash_by_src(net, nf_ct_zone(ct), &new_tuple);
+		manip_src_lock = &nf_nat_manip_src_locks[manip_src_hash % CONNTRACK_LOCKS];
+		spin_lock_bh(manip_src_lock);
+
+		/* The port search checked the 3-tuple without holding its
+		 * bucket lock. Check it again and add the entry in the same
+		 * critical section, or two fullcone bindings racing for one
+		 * translated source could both take it.
+		 */
+		if (fullcone &&
+		    nf_nat_3_tuple_taken(&new_tuple, ct, manip_src_hash)) {
+			spin_unlock_bh(manip_src_lock);
+			if (++retries == NF_NAT_FULLCONE_RETRIES) {
+				ret = NF_DROP;
+				goto out;
+			}
+			if (range != &retry_range) {
+				retry_range = *range;
+				retry_range.flags |= NF_NAT_RANGE_PROTO_RANDOM_FULLY;
+				range = &retry_range;
+			}
+			goto again;
+		}
 	}
 
 	if (!nf_ct_tuple_equal(&new_tuple, &curr_tuple)) {
@@ -936,21 +1035,21 @@ nf_nat_setup_info(struct nf_conn *ct,
 			ct->status |= IPS_DST_NAT;
 
 		if (nfct_help(ct) && !nfct_seqadj(ct))
-			if (!nfct_seqadj_ext_add(ct))
-				return NF_DROP;
+			if (!nfct_seqadj_ext_add(ct)) {
+				if (manip_src_lock)
+					spin_unlock_bh(manip_src_lock);
+				ret = NF_DROP;
+				goto out;
+			}
 	}
 
 	if (maniptype == NF_NAT_MANIP_SRC) {
 		unsigned int srchash;
-		unsigned int manip_src_hash;
 		spinlock_t *lock;
 
-		manip_src_hash = hash_by_src(net, nf_ct_zone(ct), &new_tuple);
-		lock = &nf_nat_manip_src_locks[manip_src_hash % CONNTRACK_LOCKS];
-		spin_lock_bh(lock);
 		hlist_add_head_rcu(&ct->nat_by_manip_src,
 				   &nf_nat_by_manip_src[manip_src_hash]);
-		spin_unlock_bh(lock);
+		spin_unlock_bh(manip_src_lock);
 
 		srchash = hash_by_src(net, nf_ct_zone(ct),
 				      &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple);
@@ -967,7 +1066,11 @@ nf_nat_setup_info(struct nf_conn *ct,
 	else
 		ct->status |= IPS_SRC_NAT_DONE;
 
-	return NF_ACCEPT;
+	ret = NF_ACCEPT;
+out:
+	if (fullcone_lock)
+		spin_unlock_bh(fullcone_lock);
+	return ret;
 }
 EXPORT_SYMBOL(nf_nat_setup_info);
 
@@ -1504,6 +1607,7 @@ static int __init nf_nat_init(void)
 	for (i = 0; i < CONNTRACK_LOCKS; i++) {
 		spin_lock_init(&nf_nat_locks[i]);
 		spin_lock_init(&nf_nat_manip_src_locks[i]);
+		spin_lock_init(&nf_nat_fullcone_locks[i]);
 	}
 
 	ret = register_pernet_subsys(&nat_net_ops);
__SONIC_EOF_3__
echo "[diy]   -> package/network/utils/iptables/patches/901-sonic-fullcone.patch"
cat > "package/network/utils/iptables/patches/901-sonic-fullcone.patch" <<'__SONIC_EOF_4__'
From: openwrt-sonic-fullcone contributors
Date: Wed, 9 Apr 2026 00:00:00 +0000
Subject: [PATCH] libxt_NAT: register FULLCONE target for SONiC fullcone NAT

Registers a new iptables target "FULLCONE" in libxt_NAT.c. The
target reuses the same options as MASQUERADE (--to-ports, --random,
--random-fully) and the same targetsize (nf_nat_ipv4_multi_range_compat
for IPv4, nf_nat_range for IPv6).

The kernel side (985 patch) implements the FULLCONE target with
bidirectional hook support (PREROUTING + POSTROUTING), enabling both
EIM and EIF for fw3/iptables.

Usage:
  iptables -t nat -A POSTROUTING -o wan -j FULLCONE
  iptables -t nat -A PREROUTING  -i wan -j FULLCONE
---
--- a/extensions/libxt_NAT.c
+++ b/extensions/libxt_NAT.c
@@ -64,6 +64,18 @@ static void MASQUERADE_help(void)
 "				Fully randomize source port.\n");
 }
 
+static void FULLCONE_help(void)
+{
+	printf(
+"FULLCONE target options:\n"
+" --to-ports <port>[-<port>]\n"
+"				Port (range) to map to.\n"
+" --random\n"
+"				Randomize source port.\n"
+" --random-fully\n"
+"				Fully randomize source port.\n");
+}
+
 static void DNAT_help(void)
 {
 	printf(
@@ -492,6 +504,12 @@ PSX_GEN(SNAT6, RANGE2_INIT_FROM_RANGE, \
 PSX_GEN(MASQUERADE, RANGE2_INIT_FROM_IPV4_MRC, \
 	AF_INET, "masq ports: ", "--to-ports ", true, "masquerade")
 
+PSX_GEN(FULLCONE, RANGE2_INIT_FROM_IPV4_MRC, \
+	AF_INET, "fullcone ports: ", "--to-ports ", true, "fullcone")
+
+PSX_GEN(FULLCONE6, RANGE2_INIT_FROM_RANGE, \
+	AF_INET6, "fullcone ports: ", "--to-ports ", true, "fullcone")
+
 PSX_GEN(MASQUERADE6, RANGE2_INIT_FROM_RANGE, \
 	AF_INET6, "masq ports: ", "--to-ports ", true, "masquerade")
 
@@ -553,6 +571,33 @@ static struct xtables_target nat_tg_reg[
 		.xlate		= MASQUERADE6_xlate,
 	},
 	{
+		.name		= "FULLCONE",
+		.version	= XTABLES_VERSION,
+		.family		= NFPROTO_IPV4,
+		.size		= XT_ALIGN(sizeof(struct nf_nat_ipv4_multi_range_compat)),
+		.userspacesize	= XT_ALIGN(sizeof(struct nf_nat_ipv4_multi_range_compat)),
+		.help		= FULLCONE_help,
+		.x6_parse	= NAT_parse,
+		.x6_fcheck	= SNAT_fcheck,
+		.print		= FULLCONE_print,
+		.save		= FULLCONE_save,
+		.x6_options	= MASQUERADE_opts,
+		.xlate		= FULLCONE_xlate,
+	},
+	{
+		.name		= "FULLCONE",
+		.version	= XTABLES_VERSION,
+		.family		= NFPROTO_IPV6,
+		.size		= XT_ALIGN(sizeof(struct nf_nat_range)),
+		.userspacesize	= XT_ALIGN(sizeof(struct nf_nat_range)),
+		.help		= FULLCONE_help,
+		.x6_parse	= NAT_parse6,
+		.print		= FULLCONE6_print,
+		.save		= FULLCONE6_save,
+		.x6_options	= MASQUERADE_opts,
+		.xlate		= FULLCONE6_xlate,
+	},
+	{
 		.name		= "REDIRECT",
 		.version	= XTABLES_VERSION,
 		.family		= NFPROTO_IPV4,
__SONIC_EOF_4__
echo "[diy]   -> package/libs/libnftnl/patches/001-libnftnl-add-fullcone-expression-support.patch"
cat > "package/libs/libnftnl/patches/001-libnftnl-add-fullcone-expression-support.patch" <<'__SONIC_EOF_5__'
From 6c39f04febd7cfdbd474233379416babcd0fc341 Mon Sep 17 00:00:00 2001
From: Syrone Wong <wong.syrone@gmail.com>
Date: Fri, 8 Apr 2022 23:52:11 +0800
Subject: [PATCH] libnftnl: add fullcone expression support

Signed-off-by: Syrone Wong <wong.syrone@gmail.com>
---
 include/libnftnl/expr.h             |   7 ++
 include/linux/netfilter/nf_tables.h |  16 +++
 src/Makefile.am                     |   1 +
 src/expr/fullcone.c                 | 188 ++++++++++++++++++++++++++++
 src/expr_ops.c                      |   2 +
 5 files changed, 214 insertions(+)
 create mode 100644 src/expr/fullcone.c

--- a/include/libnftnl/expr.h
+++ b/include/libnftnl/expr.h
@@ -273,6 +273,13 @@ enum {
 };
 
 enum {
+	NFTNL_EXPR_FULLCONE_FLAGS		= NFTNL_EXPR_BASE,
+	NFTNL_EXPR_FULLCONE_REG_PROTO_MIN,
+	NFTNL_EXPR_FULLCONE_REG_PROTO_MAX,
+	__NFTNL_EXPR_FULLCONE_MAX
+};
+
+enum {
 	NFTNL_EXPR_REDIR_REG_PROTO_MIN	= NFTNL_EXPR_BASE,
 	NFTNL_EXPR_REDIR_REG_PROTO_MAX,
 	NFTNL_EXPR_REDIR_FLAGS,
--- a/include/linux/netfilter/nf_tables.h
+++ b/include/linux/netfilter/nf_tables.h
@@ -1510,6 +1510,22 @@ enum nft_masq_attributes {
 #define NFTA_MASQ_MAX		(__NFTA_MASQ_MAX - 1)
 
 /**
+ * enum nft_fullcone_attributes - nf_tables fullcone expression attributes
+ *
+ * @NFTA_FULLCONE_FLAGS: NAT flags (see NF_NAT_RANGE_* in linux/netfilter/nf_nat.h) (NLA_U32)
+ * @NFTA_FULLCONE_REG_PROTO_MIN: source register of proto range start (NLA_U32: nft_registers)
+ * @NFTA_FULLCONE_REG_PROTO_MAX: source register of proto range end (NLA_U32: nft_registers)
+ */
+enum nft_fullcone_attributes {
+	NFTA_FULLCONE_UNSPEC,
+	NFTA_FULLCONE_FLAGS,
+	NFTA_FULLCONE_REG_PROTO_MIN,
+	NFTA_FULLCONE_REG_PROTO_MAX,
+	__NFTA_FULLCONE_MAX
+};
+#define NFTA_FULLCONE_MAX		(__NFTA_FULLCONE_MAX - 1)
+
+/**
  * enum nft_redir_attributes - nf_tables redirect expression netlink attributes
  *
  * @NFTA_REDIR_REG_PROTO_MIN: source register of proto range start (NLA_U32: nft_registers)
--- a/src/Makefile.am
+++ b/src/Makefile.am
@@ -56,6 +56,7 @@ libnftnl_la_SOURCES = utils.c		\
 		      expr/target.c	\
 		      expr/tunnel.c	\
 		      expr/masq.c	\
+		      expr/fullcone.c	\
 		      expr/redir.c	\
 		      expr/hash.c	\
 		      expr/socket.c	\
--- /dev/null
+++ b/src/expr/fullcone.c
@@ -0,0 +1,188 @@
+/*
+ * (C) 2022-2025 wongsyrone
+ *
+ * This program is free software; you can redistribute it and/or modify
+ * it under the terms of the GNU General Public License as published
+ * by the Free Software Foundation; either version 2 of the License, or
+ * (at your option) any later version.
+ */
+
+#include <stdio.h>
+#include <stdint.h>
+#include <arpa/inet.h>
+#include <errno.h>
+#include <inttypes.h>
+
+#include <linux/netfilter/nf_tables.h>
+
+#include "internal.h"
+#include <libmnl/libmnl.h>
+#include <libnftnl/expr.h>
+#include <libnftnl/rule.h>
+
+struct nftnl_expr_fullcone {
+	uint32_t		flags;
+	enum nft_registers	sreg_proto_min;
+	enum nft_registers	sreg_proto_max;
+};
+
+static int
+nftnl_expr_fullcone_set(struct nftnl_expr *e, uint16_t type,
+			const void *data, uint32_t data_len,
+			uint32_t byteorder)
+{
+	struct nftnl_expr_fullcone *fullcone = nftnl_expr_data(e);
+
+	switch (type) {
+	case NFTNL_EXPR_FULLCONE_FLAGS:
+		memcpy(&fullcone->flags, data, data_len);
+		break;
+	case NFTNL_EXPR_FULLCONE_REG_PROTO_MIN:
+		memcpy(&fullcone->sreg_proto_min, data, data_len);
+		break;
+	case NFTNL_EXPR_FULLCONE_REG_PROTO_MAX:
+		memcpy(&fullcone->sreg_proto_max, data, data_len);
+		break;
+	default:
+		return -1;
+	}
+	return 0;
+}
+
+/* expr_ops::set prototype before libnftnl 1.3.2 (no byteorder argument) */
+static int
+nftnl_expr_fullcone_set_compat(struct nftnl_expr *e, uint16_t type,
+			       const void *data, uint32_t data_len)
+{
+	return nftnl_expr_fullcone_set(e, type, data, data_len, 0);
+}
+
+static const void *
+nftnl_expr_fullcone_get(const struct nftnl_expr *e, uint16_t type,
+		       uint32_t *data_len)
+{
+	struct nftnl_expr_fullcone *fullcone = nftnl_expr_data(e);
+
+	switch (type) {
+	case NFTNL_EXPR_FULLCONE_FLAGS:
+		*data_len = sizeof(fullcone->flags);
+		return &fullcone->flags;
+	case NFTNL_EXPR_FULLCONE_REG_PROTO_MIN:
+		*data_len = sizeof(fullcone->sreg_proto_min);
+		return &fullcone->sreg_proto_min;
+	case NFTNL_EXPR_FULLCONE_REG_PROTO_MAX:
+		*data_len = sizeof(fullcone->sreg_proto_max);
+		return &fullcone->sreg_proto_max;
+	}
+	return NULL;
+}
+
+static int nftnl_expr_fullcone_cb(const struct nlattr *attr, void *data)
+{
+	const struct nlattr **tb = data;
+	int type = mnl_attr_get_type(attr);
+
+	if (mnl_attr_type_valid(attr, NFTA_FULLCONE_MAX) < 0)
+		return MNL_CB_OK;
+
+	switch (type) {
+	case NFTA_FULLCONE_REG_PROTO_MIN:
+	case NFTA_FULLCONE_REG_PROTO_MAX:
+	case NFTA_FULLCONE_FLAGS:
+		if (mnl_attr_validate(attr, MNL_TYPE_U32) < 0)
+			abi_breakage();
+		break;
+	}
+
+	tb[type] = attr;
+	return MNL_CB_OK;
+}
+
+static void
+nftnl_expr_fullcone_build(struct nlmsghdr *nlh, const struct nftnl_expr *e)
+{
+	struct nftnl_expr_fullcone *fullcone = nftnl_expr_data(e);
+
+	if (e->flags & (1 << NFTNL_EXPR_FULLCONE_FLAGS))
+		mnl_attr_put_u32(nlh, NFTA_FULLCONE_FLAGS, htobe32(fullcone->flags));
+	if (e->flags & (1 << NFTNL_EXPR_FULLCONE_REG_PROTO_MIN))
+		mnl_attr_put_u32(nlh, NFTA_FULLCONE_REG_PROTO_MIN,
+				 htobe32(fullcone->sreg_proto_min));
+	if (e->flags & (1 << NFTNL_EXPR_FULLCONE_REG_PROTO_MAX))
+		mnl_attr_put_u32(nlh, NFTA_FULLCONE_REG_PROTO_MAX,
+				 htobe32(fullcone->sreg_proto_max));
+}
+
+static int
+nftnl_expr_fullcone_parse(struct nftnl_expr *e, struct nlattr *attr)
+{
+	struct nftnl_expr_fullcone *fullcone = nftnl_expr_data(e);
+	struct nlattr *tb[NFTA_FULLCONE_MAX+1] = {};
+
+	if (mnl_attr_parse_nested(attr, nftnl_expr_fullcone_cb, tb) < 0)
+		return -1;
+
+	if (tb[NFTA_FULLCONE_FLAGS]) {
+		fullcone->flags = be32toh(mnl_attr_get_u32(tb[NFTA_FULLCONE_FLAGS]));
+		e->flags |= (1 << NFTNL_EXPR_FULLCONE_FLAGS);
+        }
+	if (tb[NFTA_FULLCONE_REG_PROTO_MIN]) {
+		fullcone->sreg_proto_min =
+			be32toh(mnl_attr_get_u32(tb[NFTA_FULLCONE_REG_PROTO_MIN]));
+		e->flags |= (1 << NFTNL_EXPR_FULLCONE_REG_PROTO_MIN);
+	}
+	if (tb[NFTA_FULLCONE_REG_PROTO_MAX]) {
+		fullcone->sreg_proto_max =
+			be32toh(mnl_attr_get_u32(tb[NFTA_FULLCONE_REG_PROTO_MAX]));
+		e->flags |= (1 << NFTNL_EXPR_FULLCONE_REG_PROTO_MAX);
+	}
+
+	return 0;
+}
+
+static int nftnl_expr_fullcone_snprintf(char *buf, size_t remain,
+				    uint32_t flags, const struct nftnl_expr *e)
+{
+	struct nftnl_expr_fullcone *fullcone = nftnl_expr_data(e);
+	int offset = 0, ret = 0;
+
+	if (e->flags & (1 << NFTNL_EXPR_FULLCONE_REG_PROTO_MIN)) {
+		ret = snprintf(buf + offset, remain, "proto_min reg %u ",
+			       fullcone->sreg_proto_min);
+		SNPRINTF_BUFFER_SIZE(ret, remain, offset);
+	}
+	if (e->flags & (1 << NFTNL_EXPR_FULLCONE_REG_PROTO_MAX)) {
+		ret = snprintf(buf + offset, remain, "proto_max reg %u ",
+			       fullcone->sreg_proto_max);
+		SNPRINTF_BUFFER_SIZE(ret, remain, offset);
+	}
+	if (e->flags & (1 << NFTNL_EXPR_FULLCONE_FLAGS)) {
+		ret = snprintf(buf + offset, remain, "flags 0x%x ", fullcone->flags);
+		SNPRINTF_BUFFER_SIZE(ret, remain, offset);
+	}
+
+	return offset;
+}
+
+static struct attr_policy fullcone_attr_policy[__NFTNL_EXPR_FULLCONE_MAX] = {
+	[NFTNL_EXPR_FULLCONE_FLAGS]         = { .maxlen = sizeof(uint32_t) },
+	[NFTNL_EXPR_FULLCONE_REG_PROTO_MIN] = { .maxlen = sizeof(uint32_t) },
+	[NFTNL_EXPR_FULLCONE_REG_PROTO_MAX] = { .maxlen = sizeof(uint32_t) },
+};
+
+struct expr_ops expr_ops_fullcone = {
+	.name		= "fullcone",
+	.alloc_len	= sizeof(struct nftnl_expr_fullcone),
+	.nftnl_max_attr	= __NFTNL_EXPR_FULLCONE_MAX - 1,
+	.attr_policy	= fullcone_attr_policy,
+	/* pick the setter matching this libnftnl's expr_ops::set */
+	.set		= _Generic(((struct expr_ops *)0)->set,
+			int (*)(struct nftnl_expr *, uint16_t, const void *, uint32_t):
+				nftnl_expr_fullcone_set_compat,
+			default:
+				nftnl_expr_fullcone_set),
+	.get		= nftnl_expr_fullcone_get,
+	.parse		= nftnl_expr_fullcone_parse,
+	.build		= nftnl_expr_fullcone_build,
+	.output		= nftnl_expr_fullcone_snprintf,
+};
--- a/src/expr_ops.c
+++ b/src/expr_ops.c
@@ -20,6 +20,7 @@ extern struct expr_ops expr_ops_limit;
 extern struct expr_ops expr_ops_log;
 extern struct expr_ops expr_ops_lookup;
 extern struct expr_ops expr_ops_masq;
+extern struct expr_ops expr_ops_fullcone;
 extern struct expr_ops expr_ops_match;
 extern struct expr_ops expr_ops_meta;
 extern struct expr_ops expr_ops_ng;
@@ -65,6 +66,7 @@ static struct expr_ops *expr_ops[] = {
 	&expr_ops_log,
 	&expr_ops_lookup,
 	&expr_ops_masq,
+	&expr_ops_fullcone,
 	&expr_ops_match,
 	&expr_ops_meta,
 	&expr_ops_ng,
__SONIC_EOF_5__
echo "[diy]   -> package/network/utils/nftables/patches/002-nftables-add-fullcone-expression-support.patch"
cat > "package/network/utils/nftables/patches/002-nftables-add-fullcone-expression-support.patch" <<'__SONIC_EOF_6__'
From 58c89e8768711a959fdc6e953df3ea2254ff93c1 Mon Sep 17 00:00:00 2001
From: Syrone Wong <wong.syrone@gmail.com>
Date: Sat, 9 Apr 2022 00:38:51 +0800
Subject: [PATCH] nftables: add fullcone expression support

Signed-off-by: Syrone Wong <wong.syrone@gmail.com>
---
 include/linux/netfilter/nf_tables.h | 16 ++++++++++
 include/statement.h                 |  1 +
 src/netlink_delinearize.c           | 48 +++++++++++++++++++++++++++++
 src/netlink_linearize.c             |  7 +++++
 src/parser_bison.y                  | 26 ++++++++++++++++
 src/scanner.l                       |  2 ++
 src/statement.c                     |  1 +
 7 files changed, 101 insertions(+)

--- a/include/linux/netfilter/nf_tables.h
+++ b/include/linux/netfilter/nf_tables.h
@@ -1500,6 +1500,22 @@ enum nft_masq_attributes {
 #define NFTA_MASQ_MAX		(__NFTA_MASQ_MAX - 1)
 
 /**
+ * enum nft_fullcone_attributes - nf_tables fullcone expression attributes
+ *
+ * @NFTA_FULLCONE_FLAGS: NAT flags (see NF_NAT_RANGE_* in linux/netfilter/nf_nat.h) (NLA_U32)
+ * @NFTA_FULLCONE_REG_PROTO_MIN: source register of proto range start (NLA_U32: nft_registers)
+ * @NFTA_FULLCONE_REG_PROTO_MAX: source register of proto range end (NLA_U32: nft_registers)
+ */
+enum nft_fullcone_attributes {
+	NFTA_FULLCONE_UNSPEC,
+	NFTA_FULLCONE_FLAGS,
+	NFTA_FULLCONE_REG_PROTO_MIN,
+	NFTA_FULLCONE_REG_PROTO_MAX,
+	__NFTA_FULLCONE_MAX
+};
+#define NFTA_FULLCONE_MAX		(__NFTA_FULLCONE_MAX - 1)
+
+/**
  * enum nft_redir_attributes - nf_tables redirect expression netlink attributes
  *
  * @NFTA_REDIR_REG_PROTO_MIN: source register of proto range start (NLA_U32: nft_registers)
--- a/include/statement.h
+++ b/include/statement.h
@@ -129,6 +129,7 @@ enum nft_nat_etypes {
 	__NFT_NAT_SNAT = NFT_NAT_SNAT,
 	__NFT_NAT_DNAT = NFT_NAT_DNAT,
 	NFT_NAT_MASQ,
+	NFT_NAT_FULLCONE,
 	NFT_NAT_REDIR,
 };
 
--- a/src/netlink_delinearize.c
+++ b/src/netlink_delinearize.c
@@ -1521,6 +1521,53 @@ out_err:
 	stmt_free(stmt);
 }
 
+static void netlink_parse_fullcone(struct netlink_parse_ctx *ctx,
+			       const struct location *loc,
+			       const struct nftnl_expr *nle)
+{
+	enum nft_registers reg1, reg2;
+	struct expr *proto;
+	struct stmt *stmt;
+	uint32_t flags = 0;
+
+	if (nftnl_expr_is_set(nle, NFTNL_EXPR_FULLCONE_FLAGS))
+		flags = nftnl_expr_get_u32(nle, NFTNL_EXPR_FULLCONE_FLAGS);
+
+	stmt = nat_stmt_alloc(loc, NFT_NAT_FULLCONE);
+	stmt->nat.flags = flags;
+
+	reg1 = netlink_parse_register(nle, NFTNL_EXPR_FULLCONE_REG_PROTO_MIN);
+	if (reg1) {
+		proto = netlink_get_register(ctx, loc, reg1);
+		if (proto == NULL) {
+			netlink_error(ctx, loc,
+				      "fullcone statement has no proto expression");
+			goto out_err;
+		}
+		expr_set_type(proto, &inet_service_type, BYTEORDER_BIG_ENDIAN);
+		stmt->nat.proto = proto;
+	}
+
+	reg2 = netlink_parse_register(nle, NFTNL_EXPR_FULLCONE_REG_PROTO_MAX);
+	if (reg2 && reg2 != reg1) {
+		proto = netlink_get_register(ctx, loc, reg2);
+		if (proto == NULL) {
+			netlink_error(ctx, loc,
+				      "fullcone statement has no proto expression");
+			goto out_err;
+		}
+		expr_set_type(proto, &inet_service_type, BYTEORDER_BIG_ENDIAN);
+		if (stmt->nat.proto != NULL)
+			proto = range_expr_alloc(loc, stmt->nat.proto, proto);
+		stmt->nat.proto = proto;
+	}
+
+	ctx->stmt = stmt;
+	return;
+out_err:
+	stmt_free(stmt);
+}
+
 static void netlink_parse_redir(struct netlink_parse_ctx *ctx,
 				const struct location *loc,
 				const struct nftnl_expr *nle)
@@ -1952,6 +1999,7 @@ static const struct expr_handler netlink
 	{ .name = "tproxy",	.parse = netlink_parse_tproxy },
 	{ .name = "notrack",	.parse = netlink_parse_notrack },
 	{ .name = "masq",	.parse = netlink_parse_masq },
+	{ .name = "fullcone",	.parse = netlink_parse_fullcone },
 	{ .name = "redir",	.parse = netlink_parse_redir },
 	{ .name = "dup",	.parse = netlink_parse_dup },
 	{ .name = "queue",	.parse = netlink_parse_queue },
--- a/src/netlink_linearize.c
+++ b/src/netlink_linearize.c
@@ -1266,6 +1266,13 @@ static void netlink_gen_nat_stmt(struct
 		nftnl_reg_pmin = NFTNL_EXPR_MASQ_REG_PROTO_MIN;
 		nftnl_reg_pmax = NFTNL_EXPR_MASQ_REG_PROTO_MAX;
 		break;
+	case NFT_NAT_FULLCONE:
+		nle = alloc_nft_expr("fullcone");
+
+		nftnl_flag_attr = NFTNL_EXPR_FULLCONE_FLAGS;
+		nftnl_reg_pmin = NFTNL_EXPR_FULLCONE_REG_PROTO_MIN;
+		nftnl_reg_pmax = NFTNL_EXPR_FULLCONE_REG_PROTO_MAX;
+		break;
 	case NFT_NAT_REDIR:
 		nle = alloc_nft_expr("redir");
 
--- a/src/parser_bison.y
+++ b/src/parser_bison.y
@@ -668,6 +668,7 @@ int nft_lex(void *, void *, void *);
 %token SNAT			"snat"
 %token DNAT			"dnat"
 %token MASQUERADE		"masquerade"
+%token FULLCONE		"fullcone"
 %token REDIRECT			"redirect"
 %token RANDOM			"random"
 %token FULLY_RANDOM		"fully-random"
@@ -816,6 +817,8 @@ int nft_lex(void *, void *, void *);
 %destructor { stmt_free($$); }	reject_stmt reject_stmt_alloc
 %type <stmt>			nat_stmt nat_stmt_alloc masq_stmt masq_stmt_alloc redir_stmt redir_stmt_alloc
 %destructor { stmt_free($$); }	nat_stmt nat_stmt_alloc masq_stmt masq_stmt_alloc redir_stmt redir_stmt_alloc
+%type <stmt>			fullcone_stmt fullcone_stmt_alloc
+%destructor { stmt_free($$); }	fullcone_stmt fullcone_stmt_alloc
 %type <val>			nf_nat_flags nf_nat_flag offset_opt
 %type <stmt>			tproxy_stmt
 %destructor { stmt_free($$); }	tproxy_stmt
@@ -3274,6 +3277,7 @@ stmt			:	verdict_stmt
 			|	queue_stmt
 			|	ct_stmt
 			|	masq_stmt	close_scope_nat
+			|	fullcone_stmt	close_scope_nat
 			|	redir_stmt	close_scope_nat
 			|	dup_stmt	close_scope_dup
 			|	fwd_stmt	close_scope_fwd
@@ -4105,6 +4109,28 @@ masq_stmt_args		:	TO 	COLON	stmt_expr
 			{
 				$<stmt>0->nat.proto = $3;
 			}
+			|	TO 	COLON	stmt_expr	nf_nat_flags
+			{
+				$<stmt>0->nat.proto = $3;
+				$<stmt>0->nat.flags = $4;
+			}
+			|	nf_nat_flags
+			{
+				$<stmt>0->nat.flags = $1;
+			}
+			;
+
+fullcone_stmt		:	fullcone_stmt_alloc		fullcone_stmt_args
+			|	fullcone_stmt_alloc
+			;
+
+fullcone_stmt_alloc		:	FULLCONE	{ $$ = nat_stmt_alloc(&@$, NFT_NAT_FULLCONE); }
+			;
+
+fullcone_stmt_args		:	TO 	COLON	stmt_expr
+			{
+				$<stmt>0->nat.proto = $3;
+			}
 			|	TO 	COLON	stmt_expr	nf_nat_flags
 			{
 				$<stmt>0->nat.proto = $3;
--- a/src/scanner.l
+++ b/src/scanner.l
@@ -478,6 +478,8 @@ addrstring	({macaddr}|{ip4addr}|{ip6addr
 	"port"			{ return PORT; }
 }
 
+<*>"fullcone"		{ scanner_push_start_cond(yyscanner, SCANSTATE_STMT_NAT); return FULLCONE; }
+
 <SCANSTATE_AT>{
 	"ll"			{ return LL_HDR; }
 	"nh"			{ return NETWORK_HDR; }
--- a/src/statement.c
+++ b/src/statement.c
@@ -681,6 +681,7 @@ const char *nat_etype2str(enum nft_nat_e
 		[NFT_NAT_SNAT]	= "snat",
 		[NFT_NAT_DNAT]	= "dnat",
 		[NFT_NAT_MASQ]	= "masquerade",
+		[NFT_NAT_FULLCONE] = "fullcone",
 		[NFT_NAT_REDIR]	= "redirect",
 	};
 
__SONIC_EOF_6__
echo "[diy]   -> package/network/utils/nftables/patches/003-nftables-handle-fullcone-in-json-parser-and-optimizer.patch"
cat > "package/network/utils/nftables/patches/003-nftables-handle-fullcone-in-json-parser-and-optimizer.patch" <<'__SONIC_EOF_7__'
From: mufeng05 <gjilkiop@qq.com>
Date: Mon, 3 Nov 2026 12:00:00 +0800
Subject: [PATCH] nftables: handle fullcone in the JSON parser and the optimizer

The fullcone patch adds NFT_NAT_FULLCONE between NFT_NAT_MASQ and
NFT_NAT_REDIR, but three places that switch on or index by the NAT type
were not updated:

- nat_type_parse() in the JSON parser looks the type up in a table
  indexed by it. The table now has a NULL entry at the fullcone index,
  and strcmp() on it crashes nft whenever JSON input has a redirect
  statement. JSON input also does not accept "fullcone", although
  nft -j prints it.
- __stmt_type_eq() in the optimizer has no case for it and hits
  assert(0) when nft -o compares two fullcone statements.
- stmt_name() has no case for it either.

Add fullcone to all three. The optimizer never merges rules on a
fullcone statement: merge_nat() has no fullcone form and would turn the
port range into an address map.

Signed-off-by: mufeng05 <gjilkiop@qq.com>
---
 src/evaluate.c    | 2 ++
 src/optimize.c    | 6 ++++++
 src/parser_json.c | 2 ++
 3 files changed, 10 insertions(+)

--- a/src/evaluate.c
+++ b/src/evaluate.c
@@ -87,6 +87,8 @@ const char *stmt_name(const struct stmt *stmt)
 			return "redirect";
 		case NFT_NAT_MASQ:
 			return "masquerade";
+		case NFT_NAT_FULLCONE:
+			return "fullcone";
 		}
 		break;
 	default:
--- a/src/optimize.c
+++ b/src/optimize.c
@@ -300,6 +300,12 @@ static bool __stmt_type_eq(const struct stmt *stmt_a, const struct stmt *stmt_b,
 			break;
 		case NFT_NAT_MASQ:
 			break;
+		case NFT_NAT_FULLCONE:
+			/* Track fullcone like the other statements, but never
+			 * merge rules on it: merge_nat() has no fullcone form
+			 * and would turn the port range into an address map.
+			 */
+			return !fully_compare;
 		case NFT_NAT_REDIR:
 			if ((stmt_a->nat.proto &&
 			     stmt_a->nat.proto->etype != EXPR_SYMBOL &&
--- a/src/parser_json.c
+++ b/src/parser_json.c
@@ -2296,6 +2296,7 @@ static int nat_type_parse(const char *type)
 		[NFT_NAT_SNAT]	= "snat",
 		[NFT_NAT_DNAT]	= "dnat",
 		[NFT_NAT_MASQ]	= "masquerade",
+		[NFT_NAT_FULLCONE] = "fullcone",
 		[NFT_NAT_REDIR]	= "redirect",
 	};
 	size_t i;
@@ -2913,6 +2914,7 @@ static struct stmt *json_parse_stmt(struct json_ctx *ctx, json_t *root)
 		{ "snat", json_parse_nat_stmt },
 		{ "dnat", json_parse_nat_stmt },
 		{ "masquerade", json_parse_nat_stmt },
+		{ "fullcone", json_parse_nat_stmt },
 		{ "redirect", json_parse_nat_stmt },
 		{ "reject", json_parse_reject_stmt },
 		{ "set", json_parse_set_stmt },
__SONIC_EOF_7__
echo "[diy]   -> package/network/config/firewall/patches/001-sonic-fullcone.patch"
cat > "package/network/config/firewall/patches/001-sonic-fullcone.patch" <<'__SONIC_EOF_8__'
From: openwrt-sonic-fullcone contributors
Date: Wed, 9 Apr 2026 00:00:00 +0000
Subject: [PATCH] firewall3: add SONiC fullcone NAT with per-zone and
 per-protocol control

Adds zone-level fullcone option with fullcone_proto list to firewall3.
defaults.fullcone is a global gate. When the kernel does not offer the
FULLCONE target, fw3 warns and keeps ordinary masquerading.

Uses native fw3 parse infrastructure (FW3_OPT / FW3_LIST) — no manual
uci_lookup_option calls. fullcone_proto goes through fw3_parse_protocol
after looking up the names musl does not know (udplite, sctp, dccp).

Requires 984 (kernel NAT core) + 985 (kernel FULLCONE target) +
901 (iptables userspace FULLCONE target) patches. Uses "FULLCONE"
target which supports both PREROUTING and POSTROUTING hooks,
providing full EIM+EIF.

Fullcone covers TCP, UDP, UDP-Lite, SCTP and DCCP, the protocols with
ports, or the subset fullcone_proto lists; other traffic keeps ordinary
masquerading. POSTROUTING rules take the zone's masq_src/masq_dest
restrictions, are each followed by the masquerade rule with the same
restrictions, and map to ports 1024-65535; iptables takes no port range
for UDP-Lite. The PREROUTING rules are emitted once per zone, after
port forwards, and take no address restrictions: they only send packets
to existing mappings.
---
 defaults.c |   6 +++
 options.h  |   4 ++
 zones.c    | 159 ++++++++++++++++++++++++++++++++++++++++++++++++++++++
 3 files changed, 169 insertions(+)

--- a/defaults.c
+++ b/defaults.c
@@ -49,6 +49,8 @@ const struct fw3_option fw3_flag_opts[] = {
 	FW3_OPT("synflood_rate",       limit,    defaults, syn_flood_rate),
 	FW3_OPT("synflood_burst",      int,      defaults, syn_flood_rate.burst),
 
+	FW3_OPT("fullcone",           bool,     defaults, fullcone),
+
 	FW3_OPT("tcp_syncookies",      bool,     defaults, tcp_syncookies),
 	FW3_OPT("tcp_ecn",             int,      defaults, tcp_ecn),
 	FW3_OPT("tcp_window_scaling",  bool,     defaults, tcp_window_scaling),
@@ -163,6 +165,10 @@ fw3_load_defaults(struct fw3_state *state, struct uci_package *p)
 
 		/* exists in both ipv4 and ipv6, if at all, so only check ipv4 */
 		check_target(e, &defs->flow_offloading, "FLOWOFFLOAD", false);
+
+		/* fw3 only generates FULLCONE rules for ipv4 */
+		if (defs->fullcone)
+			check_target(e, &defs->fullcone, "FULLCONE", false);
 	}
 }
 
--- a/options.h
+++ b/options.h
@@ -297,6 +297,7 @@ struct fw3_defaults
 	enum fw3_reject_code any_reject_code;
 
 	bool syn_flood;
+	bool fullcone;
 	struct fw3_limit syn_flood_rate;
 
 	bool tcp_syncookies;
@@ -343,6 +344,9 @@ struct fw3_zone
 
 	bool mtu_fix;
 
+	bool fullcone;
+	struct list_head fullcone_proto;
+
 	struct list_head cthelpers;
 
 	int log;
--- a/zones.c
+++ b/zones.c
@@ -58,6 +58,49 @@ enum fw3_zone_logmask {
 	FW3_ZONE_LOG_MANGLE = (1 << 1),
 };
 
+/* SONiC fullcone applies to the protocols with ports. musl does not know
+ * all of their names, so fullcone_proto looks them up here first.
+ */
+static const struct {
+	const char *name;
+	uint32_t protocol;
+} fullcone_protos[] = {
+	{ "tcp",     IPPROTO_TCP     },
+	{ "udp",     IPPROTO_UDP     },
+	{ "udplite", IPPROTO_UDPLITE },
+	{ "sctp",    IPPROTO_SCTP    },
+	{ "dccp",    IPPROTO_DCCP    },
+};
+
+/* Stands in for an entry fw3_parse_protocol() rejected */
+#define FULLCONE_PROTO_INVALID	256
+
+static bool
+fw3_parse_fullcone_proto(void *ptr, const char *val, bool is_list)
+{
+	char num[sizeof("4294967295")];
+	unsigned int i;
+
+	for (i = 0; i < ARRAY_SIZE(fullcone_protos); i++)
+	{
+		if (!strcmp(val, fullcone_protos[i].name))
+		{
+			snprintf(num, sizeof(num), "%u", fullcone_protos[i].protocol);
+			return fw3_parse_protocol(ptr, num, is_list);
+		}
+	}
+
+	if (fw3_parse_protocol(ptr, val, is_list))
+		return true;
+
+	/* Keep the entry, so that a list of invalid ones does not read as
+	 * an empty list, which means all protocols.
+	 */
+	snprintf(num, sizeof(num), "%u", FULLCONE_PROTO_INVALID);
+	fw3_parse_protocol(ptr, num, is_list);
+	return false;
+}
+
 const struct fw3_option fw3_zone_opts[] = {
 	FW3_OPT("enabled",             bool,     zone,     enabled),
 
@@ -84,6 +127,9 @@ const struct fw3_option fw3_zone_opts[] = {
 	FW3_OPT("mtu_fix",             bool,     zone,     mtu_fix),
 	FW3_OPT("custom_chains",       bool,     zone,     custom_chains),
 
+	FW3_OPT("fullcone",            bool,     zone,     fullcone),
+	FW3_LIST("fullcone_proto",     fullcone_proto, zone, fullcone_proto),
+
 	FW3_OPT("log",                 int,      zone,     log),
 	FW3_OPT("log_limit",           limit,    zone,     log_limit),
 
@@ -134,6 +180,62 @@ check_masq_addrs(struct list_head *head)
 	return (n_addr == 0 || n_failed < n_addr);
 }
 
+static bool
+fullcone_proto_listed(struct fw3_zone *zone, uint32_t protocol)
+{
+	struct fw3_protocol *proto;
+
+	if (list_empty(&zone->fullcone_proto))
+		return true;
+
+	list_for_each_entry(proto, &zone->fullcone_proto, list)
+	{
+		if (proto->any || (!proto->invert && proto->protocol == protocol))
+			return true;
+	}
+
+	return false;
+}
+
+static void
+check_fullcone_proto(struct uci_element *e, struct fw3_zone *zone)
+{
+	struct fw3_protocol *proto;
+	bool applicable = false;
+	unsigned int i;
+
+	if (list_empty(&zone->fullcone_proto))
+		return;
+
+	list_for_each_entry(proto, &zone->fullcone_proto, list)
+	{
+		if (proto->any)
+			return;
+	}
+
+	list_for_each_entry(proto, &zone->fullcone_proto, list)
+	{
+		for (i = 0; i < ARRAY_SIZE(fullcone_protos); i++)
+		{
+			if (!proto->invert && proto->protocol == fullcone_protos[i].protocol)
+				break;
+		}
+
+		if (i < ARRAY_SIZE(fullcone_protos))
+			applicable = true;
+		else if (proto->protocol != FULLCONE_PROTO_INVALID)
+			warn_elem(e, "ignores fullcone_proto %s%s, fullcone only applies "
+			             "to tcp, udp, udplite, sctp and dccp",
+			          proto->invert ? "!" : "", fw3_protoname(proto));
+	}
+
+	if (!applicable)
+	{
+		warn_elem(e, "has no applicable fullcone_proto, disabling fullcone");
+		zone->fullcone = false;
+	}
+}
+
 static void
 resolve_networks(struct uci_element *e, struct fw3_zone *zone)
 {
@@ -216,6 +318,7 @@ fw3_alloc_zone(void)
 	INIT_LIST_HEAD(&zone->masq_src);
 	INIT_LIST_HEAD(&zone->masq_dest);
 	INIT_LIST_HEAD(&zone->cthelpers);
+	INIT_LIST_HEAD(&zone->fullcone_proto);
 
 	INIT_LIST_HEAD(&zone->old_addrs);
 
@@ -267,6 +370,9 @@ fw3_load_zones(struct fw3_state *state, struct uci_package *p)
 		if (!defs->auto_helper && zone->auto_helper)
 			zone->auto_helper = false;
 
+		if (!defs->fullcone && zone->fullcone)
+			zone->fullcone = false;
+
 		if (!zone->name || !*zone->name)
 		{
 			warn_elem(e, "has no name - ignoring");
@@ -308,9 +414,17 @@ fw3_load_zones(struct fw3_state *state, struct uci_package *p)
 
 		resolve_networks(e, zone);
 
+		if (zone->fullcone)
+			check_fullcone_proto(e, zone);
+
 		if (zone->masq)
 		{
 			fw3_setbit(zone->flags[0], FW3_FLAG_SNAT);
+			/* SONiC fullcone needs PREROUTING for reverse mapping (EIF),
+			 * so request DNAT chain creation when fullcone is enabled.
+			 */
+			if (zone->fullcone)
+				fw3_setbit(zone->flags[0], FW3_FLAG_DNAT);
 		}
 
 		if (zone->custom_chains)
@@ -662,6 +776,40 @@ next_addr(struct fw3_address *addr, struct list_head *list,
 	return NULL;
 }
 
+static void
+print_fullcone_rules(struct fw3_ipt_handle *handle, struct fw3_zone *zone,
+                     struct fw3_address *src, struct fw3_address *dest,
+                     bool snat)
+{
+	struct fw3_protocol proto = { };
+	struct fw3_ipt_rule *r;
+	unsigned int i;
+
+	for (i = 0; i < ARRAY_SIZE(fullcone_protos); i++)
+	{
+		proto.protocol = fullcone_protos[i].protocol;
+
+		if (!fullcone_proto_listed(zone, proto.protocol))
+			continue;
+
+		r = fw3_ipt_rule_new(handle);
+		fw3_ipt_rule_proto(r, &proto);
+		fw3_ipt_rule_src_dest(r, src, dest);
+		fw3_ipt_rule_target(r, "FULLCONE");
+
+		/* The port range keeps translated ports out of the privileged
+		 * range, and the SONiC patch enforces 3-tuple uniqueness only
+		 * for rules that have one. iptables takes no port range for
+		 * UDP-Lite.
+		 */
+		if (snat && proto.protocol != IPPROTO_UDPLITE)
+			fw3_ipt_rule_addarg(r, false, "--to-ports", "1024-65535");
+
+		fw3_ipt_rule_append(r, "zone_%s_%srouting", zone->name,
+		                    snat ? "post" : "pre");
+	}
+}
+
 static void
 print_zone_rule(struct fw3_ipt_handle *handle, struct fw3_state *state,
                 bool reload, struct fw3_zone *zone)
@@ -753,12 +901,23 @@ print_zone_rule(struct fw3_ipt_handle *handle, struct fw3_state *state,
 					                    handle->family, false)) || first_dest;
 				     first_dest = false)
 				{
+					/* Fullcone first, masquerade for the rest */
+					if (zone->fullcone)
+						print_fullcone_rules(handle, zone, msrc, mdest, true);
+
 					r = fw3_ipt_rule_new(handle);
 					fw3_ipt_rule_src_dest(r, msrc, mdest);
 					fw3_ipt_rule_target(r, "MASQUERADE");
 					fw3_ipt_rule_append(r, "zone_%s_postrouting", zone->name);
 				}
 			}
+
+			/* PREROUTING: DNAT reverse mapping for EIF, once per zone.
+			 * No address restrictions here: the kernel only follows
+			 * mappings set up by the POSTROUTING rules above.
+			 */
+			if (zone->fullcone)
+				print_fullcone_rules(handle, zone, NULL, NULL, false);
 		}
 		break;
 
__SONIC_EOF_8__
echo "[diy]   -> package/network/config/firewall4/patches/001-sonic-fullcone.patch"
cat > "package/network/config/firewall4/patches/001-sonic-fullcone.patch" <<'__SONIC_EOF_9__'
From: openwrt-sonic-fullcone contributors
Date: Wed, 9 Apr 2026 00:00:00 +0000
Subject: [PATCH] firewall4: add SONiC fullcone NAT with per-zone and
 per-protocol granularity

Adds fullcone NAT support to firewall4 with three levels of control:

  1. Global default:  config defaults / option fullcone 1
  2. Per-zone:        config zone / option fullcone 1
  3. Per-protocol:    config zone / list fullcone_proto udp

defaults.fullcone is a global gate. When off, all fullcone is disabled.
When on, each zone must explicitly set fullcone=1 to activate.

Requires the fullcone expression in nft_masq.ko (from the
986-add-sonic-fullcone-to-nft patch) and the corresponding
libnftnl/nftables userspace patches.

Fullcone covers TCP, UDP, UDP-Lite, SCTP and DCCP, the protocols with
ports, or the subset fullcone_proto lists; other traffic keeps ordinary
masquerading. In srcnat each fullcone rule takes the zone's masq_src and
masq_dest restrictions and is followed by the masquerade rule with the
same restrictions. SNAT rules map to ports 1024-65535; DNAT rules carry
no range and no address restrictions.
---
 root/usr/share/firewall4/templates/ruleset.uc       | 12 ++
 root/usr/share/firewall4/templates/zone-fullcone.uc | 35 ++++++
 root/usr/share/ucode/fw4.uc                         | 89 ++++++++++++++-
 3 files changed, 135 insertions(+), 1 deletion(-)

--- a/root/usr/share/firewall4/templates/ruleset.uc
+++ b/root/usr/share/firewall4/templates/ruleset.uc
@@ -333,6 +333,12 @@ table inet fw4 {
 {%   for (let redirect in fw4.redirects(`dstnat_${zone.name}`)): %}
 		{%+ include("redirect.uc", { fw4, zone, redirect }) %}
 {%   endfor %}
+{%   if (zone.masq && zone.fullcone): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 4, direction: "dstnat" }) %}
+{%   endif %}
+{%   if (zone.masq6 && zone.fullcone6): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 6, direction: "dstnat" }) %}
+{%   endif %}
 {%   fw4.includes('chain-append', `dstnat_${zone.name}`) %}
 	}
 
@@ -346,6 +352,9 @@ table inet fw4 {
 {%   if (zone.masq): %}
 {%    for (let saddrs in zone.masq4_src_subnets): %}
 {%     for (let daddrs in zone.masq4_dest_subnets): %}
+{%      if (zone.fullcone): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 4, direction: "srcnat", saddrs, daddrs }) %}
+{%      endif %}
 		{%+ include("zone-masq.uc", { fw4, zone, family: 4, saddrs, daddrs }) %}
 {%     endfor %}
 {%    endfor %}
@@ -353,6 +362,9 @@ table inet fw4 {
 {%   if (zone.masq6): %}
 {%    for (let saddrs in zone.masq6_src_subnets): %}
 {%     for (let daddrs in zone.masq6_dest_subnets): %}
+{%      if (zone.fullcone6): %}
+		{%+ include("zone-fullcone.uc", { fw4, zone, family: 6, direction: "srcnat", saddrs, daddrs }) %}
+{%      endif %}
 		{%+ include("zone-masq.uc", { fw4, zone, family: 6, saddrs, daddrs }) %}
 {%     endfor %}
 {%    endfor %}
--- /dev/null
+++ b/root/usr/share/firewall4/templates/zone-fullcone.uc
@@ -0,0 +1,35 @@
+{# /usr/share/firewall4/templates/zone-fullcone.uc
+   direction: "srcnat" or "dstnat"
+   saddrs, daddrs: masquerading restrictions, srcnat only
+
+   Fullcone covers the protocols in zone.fullcone_proto, which fw4.uc keeps
+   to those with ports, the only ones the kernel can key a mapping by. In
+   srcnat the rule takes the same address restrictions as the masquerade
+   rule zone-masq.uc emits right after it, which handles all other traffic.
+   dstnat takes none: it only follows existing mappings, which for these
+   protocols the srcnat fullcone rule sets up.
+
+   The srcnat port range keeps translated ports out of the privileged
+   range, and the SONiC patch enforces 3-tuple uniqueness only for rules
+   that have one.
+
+   The set is joined here rather than with fw4.set(): that quotes anything
+   that is not an address, and nft does not resolve a quoted protocol name.
+ -#}
+{%
+	let l4 = map(zone.fullcone_proto, (name) => fw4.l4proto(family, { name }));
+	let snat = (direction == "srcnat");
+-%}
+meta nfproto {{ fw4.nfproto(family) }} {%+ if (snat && saddrs && saddrs[0]): -%}
+	{{ fw4.ipproto(family) }} saddr {{ fw4.set(map(saddrs[0], fw4.cidr)) }} {%+ endif -%}
+{%+ if (snat && saddrs && saddrs[1]): -%}
+	{{ fw4.ipproto(family) }} saddr != {{ fw4.set(map(saddrs[1], fw4.cidr)) }} {%+ endif -%}
+{%+ for (let a in (snat && saddrs ? saddrs[2] : [])): -%}
+	{{ fw4.ipproto(family) }} saddr & {{ a.mask }} {{ a.invert ? '!=' : '==' }} {{ a.addr }} {%+ endfor -%}
+{%+ if (snat && daddrs && daddrs[0]): -%}
+	{{ fw4.ipproto(family) }} daddr {{ fw4.set(map(daddrs[0], fw4.cidr)) }} {%+ endif -%}
+{%+ if (snat && daddrs && daddrs[1]): -%}
+	{{ fw4.ipproto(family) }} daddr != {{ fw4.set(map(daddrs[1], fw4.cidr)) }} {%+ endif -%}
+{%+ for (let a in (snat && daddrs ? daddrs[2] : [])): -%}
+	{{ fw4.ipproto(family) }} daddr & {{ a.mask }} {{ a.invert ? '!=' : '==' }} {{ a.addr }} {%+ endfor -%}
+meta l4proto {{ length(l4) > 1 ? "{ " + join(", ", l4) + " }" : l4[0] }} fullcone{{ snat ? " to :1024-65535" : "" }} comment "!fw4: {{ zone.name }} {{ fw4.nfproto(family, true) }} fullcone NAT {{ direction }}"
--- a/root/usr/share/ucode/fw4.uc
+++ b/root/usr/share/ucode/fw4.uc
@@ -503,6 +503,32 @@ function nft_try_hw_offload(devices) {
 	return (rc == 0);
 }
 
+/* Protocols the kernel can key a fullcone mapping by: those with ports. */
+const FULLCONE_PROTOS = [ "tcp", "udp", "udplite", "sctp", "dccp" ];
+
+function nft_try_fullcone() {
+	/* Probe the forms zone-fullcone.uc emits. srcnat carries a port range,
+	 * and a kernel that has the expression but not its range attributes
+	 * should turn fullcone off here rather than fail the whole ruleset. */
+	let nft_test =
+		'add table inet fw4-fullcone-test; ' +
+		'add chain inet fw4-fullcone-test dstnat { ' +
+			'type nat hook prerouting priority -100; policy accept; ' +
+			'fullcone; ' +
+		'}; ' +
+		'add chain inet fw4-fullcone-test srcnat { ' +
+			'type nat hook postrouting priority -100; policy accept; ' +
+			'meta l4proto { tcp, udp } fullcone to :1024-65535; ' +
+			'fullcone; ' +
+		'}; ';
+	let cmd = sprintf("/usr/sbin/nft -c '%s' 2>/dev/null", replace(nft_test, "'", "'\\''"));
+	system("/sbin/modprobe nft_masq 2>/dev/null"); let ok = system(cmd) == 0;
+	if (!ok) {
+		warn("nft_try_fullcone: fullcone expression not available in kernel\n");
+	}
+	return ok;
+}
+
 
 return {
 	read_kernel_version: function() {
@@ -1530,6 +1556,7 @@ return {
 			"helper",
 			"mark",
 			"dscp",
+			"fullcone",
 			"dnat",
 			"snat",
 			"masquerade",
@@ -2020,6 +2047,7 @@ return {
 		}
 
 		let defs = this.parse_options(data, {
+			fullcone: [ "bool", "0" ],
 			input: [ "policy", "drop" ],
 			output: [ "policy", "drop" ],
 			forward: [ "policy", "drop" ],
@@ -2054,6 +2082,13 @@ return {
 
 		delete defs.syn_flood;
 
+		if (defs.fullcone) {
+			if (!nft_try_fullcone()) {
+				delete defs.fullcone;
+				warn("fullcone expression not available, disabling fullcone globally\n");
+			}
+		}
+
 		this.state.defaults = defs;
 	},
 
@@ -2083,6 +2118,9 @@ return {
 
 			masq6: [ "bool" ],
 
+			fullcone: [ "bool" ],
+			fullcone_proto: [ "protocol", null, PARSE_LIST | FLATTEN_LIST ],
+
 			extra: [ "string", null, UNSUPPORTED ],
 			extra_src: [ "string", null, UNSUPPORTED ],
 			extra_dest: [ "string", null, UNSUPPORTED ],
@@ -2130,6 +2168,42 @@ return {
 			}
 		}
 
+		/* SONiC fullcone: defaults.fullcone is a global gate.
+		 * When off, all fullcone is disabled regardless of zone config.
+		 * When on, each zone must explicitly set fullcone=1 to enable.
+		 *
+		 * Fullcone only covers FULLCONE_PROTOS; other traffic keeps
+		 * ordinary masquerading. An empty fullcone_proto, or one that
+		 * lists "all", means all of them.
+		 *
+		 * Flatten fullcone_proto (list of protocol objects) into plain
+		 * name strings suitable for direct use in nftables templates.
+		 */
+		zone.fullcone = !!(this.state.defaults.fullcone && zone.fullcone);
+
+		let fullcone_proto = FULLCONE_PROTOS;
+
+		if (length(zone.fullcone_proto) && !length(filter(zone.fullcone_proto, p => p?.any))) {
+			fullcone_proto = [];
+
+			for (let p in zone.fullcone_proto) {
+				if (!p)
+					continue;
+				else if (!p.invert && p.name in FULLCONE_PROTOS)
+					push(fullcone_proto, p.name);
+				else if (zone.fullcone)
+					this.warn_section(data, `option 'fullcone_proto' ignores '${p.invert ? '!' : ''}${p.name}', fullcone only applies to ${join(', ', FULLCONE_PROTOS)}`);
+			}
+
+			if (zone.fullcone && !length(fullcone_proto)) {
+				this.warn_section(data, "option 'fullcone_proto' lists no applicable protocol, disabling fullcone");
+				zone.fullcone = false;
+			}
+		}
+
+		zone.fullcone_proto = uniq(fullcone_proto);
+		zone.fullcone6 = zone.fullcone;
+
 		if (zone.mtu_fix && this.kernel < 0x040a0000) {
 			this.warn_section(data, "option 'mtu_fix' requires kernel 4.10 or later");
 			return;
@@ -2300,6 +2374,19 @@ return {
 		zone.related_physdevs = related_physdevs;
 
-		if (zone.masq || zone.masq6)
+		if (zone.masq) {
 			zone.dflags.snat = true;
+			if (zone.fullcone)
+				zone.dflags.dnat = true;
+		}
+
+		if (zone.masq6) {
+			zone.dflags.snat = true;
+			if (zone.fullcone6)
+				zone.dflags.dnat = true;
+		}
+
+		/* Like masq zones, fullcone zones get no automatic helpers. */
+		if (zone.fullcone || zone.fullcone6)
+			zone.auto_helper = false;
 
 		if ((zone.auto_helper && !(zone.masq || zone.masq6)) || length(zone.helper)) {
__SONIC_EOF_9__
echo "[diy] ✓ 10 个 sonic 补丁已写入（fw4 那份加了等长 modprobe nft_masq 保险）"

# ---------------- 3.5/4 防火墙页面开关：准备 feed 与补丁文件 ----------------
# 时序：workflow 第 5 步先跑 diy.sh，再跑 feeds update/install -a，所以本脚本
# 执行时 feeds/luci 尚不存在。这里只提前拉取 luci 这一个 feed（其余 feed 仍由
# workflow 全量拉取），补丁文件写到 /tmp；4/4 段的 Python 负责 dry-run 与放置。
#
# 已核实 OpenWrt 24.10 scripts/feeds：src-git 的 update 是 `git pull --ff-only`，
# 不删除未跟踪文件，因此 workflow 后续的 `feeds update -a` 不会把放进 patches/
# 的补丁冲掉。po/zh_Hans/firewall.po 是已跟踪文件，追加会让 git pull 冲突，
# 故本版不改；中文界面下新标签显示英文 msgid，功能不受影响。
LUCI_PKG="feeds/luci/applications/luci-app-firewall"

cat > /tmp/sonic_luci.patch <<'__LUCIPATCH_EOF__'
From: openwrt-sonic-fullcone contributors
Date: Wed, 9 Apr 2026 00:00:00 +0000
Subject: [PATCH] luci-app-firewall: add SONiC fullcone NAT options

Add fullcone NAT configuration to the firewall web interface:

  - Global "Fullcone NAT" checkbox in General Settings (global gate)
  - Per-zone "Fullcone NAT" checkbox in zone General tab
  - Per-zone "Fullcone protocols" multi-value in zone Advanced tab

defaults.fullcone is a global gate: when off, all zone-level fullcone
settings are ignored. When on, each zone must explicitly enable fullcone.
---
 htdocs/luci-static/resources/view/firewall/zones.js | 30 ++++++++++++++
 1 file changed, 30 insertions(+)

--- a/htdocs/luci-static/resources/view/firewall/zones.js
+++ b/htdocs/luci-static/resources/view/firewall/zones.js
@@ -57,2 +57,8 @@ return view.extend({
 		o = s.option(form.Flag, 'drop_invalid', _('Drop invalid packets'));
+
+		o = s.option(form.Flag, 'fullcone', _('Fullcone NAT'),
+			_('Global gate for SONiC-style fullcone NAT. When enabled, each zone can individually activate fullcone in its settings.'));
+		o.default = '0';
+		o.rmempty = true;
+		o.optional = true;
 
@@ -179,6 +185,12 @@ return view.extend({
 			return null;
 		};
 
+		o = s.taboption('general', form.Flag, 'fullcone', _('Fullcone NAT'),
+			_('Enable fullcone NAT for this zone. Requires the global Fullcone NAT gate to be enabled in General Settings. ' +
+			  'Use "Fullcone protocols" in Advanced Settings to restrict scope.'));
+		o.editable = true;
+		o.depends('masq', '1');
+
 		o = s.taboption('general', form.Flag, 'mtu_fix', _('MSS clamping'));
 		o.modalonly = true;
 
@@ -281,6 +293,24 @@ return view.extend({
 		o.placeholder = '0.0.0.0/0';
 		o.modalonly = true;
 
+		o = s.taboption('advanced', form.MultiValue, 'fullcone_proto',
+			_('Fullcone protocols'),
+			_('Restrict fullcone NAT to these protocols; when empty, all of them use fullcone. ' +
+			  'Other protocols always use ordinary masquerading. ' +
+			  'UDP-Lite, SCTP and DCCP also need kernel connection tracking support, which OpenWrt does not enable by default. ' +
+			  'Recommended: select only UDP for gaming/P2P use cases.'));
+		o.value('tcp', _('TCP'));
+		o.value('udp', _('UDP'));
+		o.value('udplite', _('UDP-Lite'));
+		o.value('sctp', _('SCTP'));
+		o.value('dccp', _('DCCP'));
+		o.depends('fullcone', '1');
+		o.modalonly = true;
+		o.optional = true;
+		o.placeholder = _('All of the above');
+		o.display_size = 5;
+		o.delimiter = ' ';
+
 		o = s.taboption('conntrack', form.Flag, 'masq_allow_invalid', _('Allow "invalid" traffic'), _('Do not install extra rules to reject forwarded traffic with conntrack state <em>invalid</em>. This may be required for complex asymmetric route setups.'));
 		o.modalonly = true;
 
__LUCIPATCH_EOF__

if [ ! -d feeds/luci/.git ]; then
  echo "[diy]   提前拉取 luci feed（仅此一个；workflow 稍后仍会全量 update -a）"
  ./scripts/feeds update luci >/tmp/diy_feeds_luci.log 2>&1 || {
    echo "[diy] ! feeds update luci 失败；4/4 段将跳过图形开关（不影响 fullcone 功能）"
    tail -8 /tmp/diy_feeds_luci.log
  }
fi

if [ -d "$LUCI_PKG" ]; then
  ./scripts/feeds install -p luci luci-app-firewall >/dev/null 2>&1 || true
  echo "[diy] ✓ luci feed 已就绪，图形开关补丁由 4/4 段做 dry-run 与放置"
else
  echo "[diy] ! luci feed 未就绪，4/4 段将跳过图形开关（不影响 fullcone 功能）"
fi


# ============================================================
# 4/4 强制源码变换 + 全量自检
# ------------------------------------------------------------
#  * 第一层：Python 逐处精确字符串替换（不依赖行号 / hunk，幂等）
#  * 第二层：JS 行级兜底（上游轻微改动导致失配时按结构安全清理）
#  * 第三层：libnftnl PKG_FIXUP、firewall.config 两层开关（已在 REPL 里）、
#            所有 sonic 补丁的 hunk 计数校验
#  * 第四层：强制自检，任一未达标立即 sys.exit(1) 终止编译
# ============================================================
cat > /tmp/diy_transform.py <<'PYEOF'
# -*- coding: utf-8 -*-
import os, re, sys, subprocess, shutil

FILES = {
 'JS':    'package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js',
 'INIT':  'package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc',
 'UCD':   'package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc',
 'MK':    'package/mtk/applications/luci-app-turboacc-mtk/Makefile',
 'RPCD':  'package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc',
 'FWCFG': 'package/network/config/firewall/files/firewall.config',
}
WS = os.environ.get('GITHUB_WORKSPACE', '')
CFG = os.path.join(WS, '.config')
LIBMK = 'package/libs/libnftnl/Makefile'
HACK = 'target/linux/generic/hack-6.6'

REPL = {
    'JS': [
        ("function formatCPUUsage(stats) {\n\tvar text = stats.CPU_USED || '0%';\n\n\tif (stats.CPU_CORES_USED) {\n\t\tif (Array.isArray(stats.CPU_CORES_USED)) {\n\t\t\tif (stats.CPU_CORES_USED.length > 0)\n\t\t\t\ttext += ' (' + stats.CPU_CORES_USED.join(', ') + ')';\n\t\t} else {\n\t\t\tvar cores = [];\n\t\t\tfor (var core in stats.CPU_CORES_USED) {\n\t\t\t\tif (stats.CPU_CORES_USED.hasOwnProperty(core))\n\t\t\t\t\tcores.push(core);\n\t\t\t}\n\t\t\tcores.sort(function (a, b) {\n\t\t\t\tvar na = parseInt(a.replace(/^CPU/i, ''), 10);\n\t\t\t\tvar nb = parseInt(b.replace(/^CPU/i, ''), 10);\n\t\t\t\treturn na - nb;\n\t\t\t});\n\t\t\tvar coreItems = [];\n\t\t\tfor (var i = 0; i < cores.length; i++) {\n\t\t\t\tvar k = cores[i];\n\t\t\t\tcoreItems.push(k + ': ' + stats.CPU_CORES_USED[k]);\n\t\t\t}\n\t\t\tif (coreItems.length > 0)\n\t\t\t\ttext += ' (' + coreItems.join(', ') + ')';\n\t\t}\n\t}\n\n\treturn text;\n", "/* Normalize the fullcone status string returned by rpcd into a\n   stable, human-readable label (independent of which implementation\n   is compiled in). */\nfunction formatStatType(t) {\n\tif (!t) return null;\n\tif (t === 'sonic_fullcone' || t === 'SONiC Fullcone')\n\t\treturn 'SONiC Fullcone (UDP)';\n\treturn t;\n"),
        ("\t\tif (stat.type) {\n\t\t\tif (stat.type.includes(' / ')) {\n\t\t\t\tvar types = stat.type.split(' / ');\n", "\t\tif (stat && stat.type) {\n\t\t\tvar stype = formatStatType(stat.type);\n\t\t\tif (stype.includes(' / ')) {\n\t\t\t\tvar types = stype.split(' / ');\n"),
        ("\t\t\t\trenderHTML.push(spanTemp.format('green', stat.type));\n", "\t\t\t\trenderHTML.push(spanTemp.format('green', stype));\n"),
        ('\t\t\t/* ---- single unified poll: status + ppe/cpu/conntrack ---- */\n', '\t\t\t/* ---- single unified poll: status + ppe ---- */\n'),
        ("\t\t\t\t\tvar conntrack_bar = document.getElementById('conntrack_state');\n\t\t\t\t\tif (conntrack_bar)\n\t\t\t\t\t\tconntrack_bar.innerHTML = E('em', {},\n\t\t\t\t\t\t\tprogressbar(parseInt(stat.Conntrack_Count), parseInt(stat.Conntrack_Max))\n\t\t\t\t\t\t).innerHTML;\n\n\t\t\t\t\tvar cpu_bar = document.getElementById('cpu_usage_state');\n\t\t\t\t\tif (cpu_bar)\n\t\t\t\t\t\tcpu_bar.innerHTML = E('em', {}, formatCPUUsage(stat)).innerHTML;\n", ''),
        ("\t\t\t}\n\t\t\tfunction ct_bar_html(stats) {\n\t\t\t\tif (!stats.Conntrack_Count) return E('em', {}, _('Collecting data...'));\n\t\t\t\treturn progressbar(parseInt(stats.Conntrack_Count), parseInt(stats.Conntrack_Max));\n\t\t\t}\n\t\t\tfunction cpu_html(stats) {\n\t\t\t\tif (!stats.CPU_USED) return E('em', {}, _('Collecting data...'));\n\t\t\t\treturn formatCPUUsage(stats);\n", ''),
        ("\t\t\t\t\t\tsvc_stats[1] && svc_stats[1].type\n\t\t\t\t\t\t\t? renderStatus(svc_stats)[1]\n\t\t\t\t\t\t\t: E('em', {}, _('Collecting data...')))\n", '\t\t\t\t\t\trenderStatus(svc_stats)[1])\n'),
        ("\t\t\t\t]),\n\t\t\t\tE('tr', {}, [\n\t\t\t\t\tE('td', { 'width': '33%' }, _('Conntrack')),\n\t\t\t\t\tE('td', { 'id': 'conntrack_state' }, ct_bar_html(ppe_stats))\n\t\t\t\t]),\n\t\t\t\tE('tr', {}, [\n\t\t\t\t\tE('td', { 'width': '33%' }, _('CPU Usage')),\n\t\t\t\t\tE('td', { 'id': 'cpu_usage_state' }, cpu_html(ppe_stats))\n", ''),
        ("\t\to = s.option(form.ListValue, 'fastpath_mh_eth_hnat_ppenum', _('Number of HNAT PPE'),\n\t\t\t_('Apply this setting after reboot.'));\n\t\to.rmempty = false;\n\t\to.value(1);\n\t\to.value(2);\n\t\to.default = 2;\n\t\to.depends('fastpath_mh_eth_hnat', '1');\n\n\t\to = s.option(form.ListValue, 'fullcone', _('Full cone NAT'),\n\t\t\t_('Full cone NAT (NAT1) can improve gaming performance effectively.'));\n\t\to.value('0', _('Disable'))\n\t\to.value('2', _('Boardcom_FULLCONE_NAT'));\n\t\to.default = '0';\n\t\to.rmempty = false;\n", '\t\t/* Full cone NAT is owned by firewall (option fullcone), not TurboACC. */\n'),
    ],
    'INIT': [
        ('\tlocal fullcone\n\tconfig_get "fullcone" "config" "fullcone" "2"\n\techo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode\n', '\t# Full cone NAT is owned by firewall4 (/etc/config/firewall: option fullcone).\n\t# Do NOT touch nf_conntrack_nat_mode here (Broadcom/BCM-NAT removed) and\n\t# do NOT reload the firewall below: rebuilding the ruleset invalidates\n\t# bound HNAT/PPE entries and causes throughput fluctuation.\n\t# (kept the same line count as upstream to stay patch-friendly)\n'),
        ('\t# Cleanup firewall rules\n\tuci -q commit "firewall"\n\t/etc/init.d/firewall restart >"/dev/null" 2>&1\n', '\t# The firewall ruleset is managed by firewall4 itself; TurboACC must not\n\t# commit or reload it here. (line count preserved)\n'),
        ('', '\n\t# --------------------------------------------------------------\n\t# sonic-fullcone 开机自愈：只在异常时动作，正常开机零干预。\n\t# 覆盖：保留配置盖掉两层开关、刷机后 rpcd 未重载（Invalid argument）。\n\t# 后台延迟 12 秒，避开 fw4 / rpcd 自身的启动顺序。\n\t# 使用 reload 而非 restart，且只做一次，不循环、不改用户已设的值。\n\t# --------------------------------------------------------------\n\t(\n\t\tsleep 12\n\t\tFW_WAN="@zone[1]"\n\t\tfor _i in 0 1 2 3 4 5; do\n\t\t\t[ "$(uci -q get firewall.@zone[$_i].name)" = "wan" ] && { FW_WAN="@zone[$_i]"; break; }\n\t\tdone\n\t\t_dirty=0\n\t\t[ -z "$(uci -q get firewall.@defaults[0].fullcone)" ] && { uci -q set firewall.@defaults[0].fullcone=1; _dirty=1; }\n\t\t[ -z "$(uci -q get firewall.$FW_WAN.fullcone)" ] && { uci -q set firewall.$FW_WAN.fullcone=1; _dirty=1; }\n\t\t[ -z "$(uci -q get firewall.$FW_WAN.fullcone_proto)" ] && { uci -q add_list firewall.$FW_WAN.fullcone_proto=udp; _dirty=1; }\n\t\t[ "$_dirty" = "1" ] && uci -q commit firewall\n\t\t_reload=0\n\t\t[ "$_dirty" = "1" ] && _reload=1\n\t\tif ! /usr/sbin/nft list ruleset 2>/dev/null | grep -q \'meta l4proto.*fullcone\'; then\n\t\t\t_reload=1\n\t\tfi\n\t\t[ "$_reload" = "1" ] && /etc/init.d/firewall reload >/dev/null 2>&1\n\t\tif ! ubus call luci.turboacc getFullConeStat >/dev/null 2>&1; then\n\t\t\t/etc/init.d/rpcd restart >/dev/null 2>&1\n\t\tfi\n\t\trm -f /tmp/luci-indexcache /tmp/luci-modulecache/*\n\t) &\n'),
    ],
    'UCD': [
        ('\tuci -q set "turboacc.config.fastpath_mh_eth_hnat_ppenum"="2"\n', ''),
        ('uci -q set "turboacc.config.fullcone"="2"\n', '# Full cone NAT is configured in /etc/config/firewall (option fullcone 1).\n# TurboACC no longer owns any fullcone setting.\n'),
        ('', '# ------------------------------------------------------------------\n# sonic-fullcone：开机默认两层开关（仅当选项缺失时补，幂等）\n# 刷机勾「保留配置」会把旧 /etc/config/firewall 带回来，其中没有\n# fullcone 选项；这里补齐，fw4 启动即可生成 fullcone 规则。\n# 用户已显式设置（含 0）则不覆盖，尊重用户选择。\n# ------------------------------------------------------------------\nFW_WAN="@zone[1]"\nfor _i in 0 1 2 3 4 5; do\n\t[ "$(uci -q get firewall.@zone[$_i].name)" = "wan" ] && { FW_WAN="@zone[$_i]"; break; }\ndone\n[ -z "$(uci -q get firewall.@defaults[0].fullcone)" ] && uci -q set firewall.@defaults[0].fullcone=1\n[ -z "$(uci -q get firewall.$FW_WAN.fullcone)" ] && uci -q set firewall.$FW_WAN.fullcone=1\n[ -z "$(uci -q get firewall.$FW_WAN.fullcone_proto)" ] && uci -q add_list firewall.$FW_WAN.fullcone_proto=udp\nuci -q commit firewall\n\n'),
    ],
    'MK': [
        ('\t+kmod-ipt-fullconenat +kmod-fs-btrfs +kmod-bonding \\\n', '\t+kmod-fs-btrfs +kmod-bonding \\\n'),
    ],
    'RPCD': [
        ('\t\t\tif fs.access("/sys/module/xt_FULLCONENAT/refcnt") and\n\t\t\t(readfile("/sys/module/xt_FULLCONENAT/refcnt") or "0") ~= "0" then\n\t\t\t\tfctype = "xt_FULLCONENAT"\n\t\t\telseif  fs.access("/proc/sys/net/netfilter/nf_conntrack_nat_mode") and\n\t\t\t\t(readfile("/proc/sys/net/netfilter/nf_conntrack_nat_mode") or "0") ~= "0" then\n\t\t\t\tfctype = "Boardcom Fullcone"\n', '\t\t\t-- sonic-fullcone has no standalone nft_fullcone.ko: the expression\n\t\t\t-- is built into nft_masq.ko, so detect the effective nft rules instead.\n\t\t\t-- Absolute path: rpcd does not always inherit /usr/sbin in PATH.\n\t\t\t-- Drop the leading-space dependency so the probe survives\n\t\t\t-- formatting changes in fw4 templates.\n\t\t\tlocal ok, n = pcall(function()\n\t\t\t\tlocal fd = io.popen("/usr/sbin/nft list ruleset 2>/dev/null | grep -c \'fullcone\'")\n\t\t\t\tif not fd then return 0 end\n\t\t\t\tlocal v = tonumber(fd:read("*l") or "0") or 0\n\t\t\t\tfd:close()\n\t\t\t\treturn v\n\t\t\tend)\n\t\t\tif ok and n > 0 then\n\t\t\t\tfctype = "sonic_fullcone"\n'),
    ],
    'FWCFG': [
        ('', "\toption fullcone\t\t1\n\tlist   fullcone_proto\t'udp'\n"),
    ],
}


SONIC_FILES = [
 'target/linux/generic/hack-6.6/984-add-sonic-fullcone-support.patch',
 'target/linux/generic/hack-6.6/985-add-sonic-fullcone-to-ipt.patch',
 'target/linux/generic/hack-6.6/986-add-sonic-fullcone-to-nft.patch',
 'target/linux/generic/hack-6.6/987-sonic-fullcone-fix-races-and-drops.patch',
 'package/network/utils/iptables/patches/901-sonic-fullcone.patch',
 'package/libs/libnftnl/patches/001-libnftnl-add-fullcone-expression-support.patch',
 'package/network/utils/nftables/patches/002-nftables-add-fullcone-expression-support.patch',
 'package/network/utils/nftables/patches/003-nftables-handle-fullcone-in-json-parser-and-optimizer.patch',
 'package/network/config/firewall/patches/001-sonic-fullcone.patch',
 'package/network/config/firewall4/patches/001-sonic-fullcone.patch',
]

def read(p):
    with open(p, 'r', encoding='utf-8', errors='surrogateescape', newline='') as f:
        return f.read()

def write(p, s):
    with open(p, 'w', encoding='utf-8', errors='surrogateescape', newline='') as f:
        f.write(s)

# ---------- 第一层：精确变换 ----------
for k, pairs in REPL.items():
    p = FILES[k]
    if not os.path.isfile(p):
        print('[diy] × 找不到文件 %s' % p); sys.exit(1)
    s = read(p); hit = 0; skipped = 0
    for old, new in pairs:
        if not old:
            # 纯插入对不能走 str.replace('', ...) —— 会插到文件开头。
            # 这类改动交给后面的专用函数按上下文处理。
            skipped += 1; continue
        if old in s:
            s = s.replace(old, new, 1); hit += 1
    write(p, s)
    print('[diy]   %s: 精确变换 %d/%d 处%s' % (k, hit, len(pairs), ('（跳过 %d 个纯插入对，由专用函数处理）' % skipped) if skipped else ''))

# ---------- 第二层：JS 行级兜底 ----------
s = read(FILES['JS']); orig = s

def remove_tr(text, marker):
    lines = text.splitlines(keepends=True); guard = 0
    while guard < 20:
        guard += 1
        idx = next((i for i, l in enumerate(lines) if marker in l), None)
        if idx is None: break
        st = None
        for j in range(idx, -1, -1):
            if "E('tr', {}, [" in lines[j]: st = j; break
            if 'var acc_rows' in lines[j]: break
        if st is None: del lines[idx]; continue
        en = None
        for j in range(st, min(len(lines), st + 30)):
            if re.match(r'^\s*\]\)\s*,?\s*$', lines[j].rstrip('\n')): en = j; break
        if en is None or en < idx: del lines[idx]; continue
        del lines[st:en + 1]
    return ''.join(lines)

def remove_func(text, name):
    sig = 'function %s(' % name
    while sig in text:
        st = text.find(sig); b = text.find('{', st)
        if b < 0: break
        depth = 0; k = b
        while k < len(text):
            if text[k] == '{': depth += 1
            elif text[k] == '}':
                depth -= 1
                if depth == 0: break
            k += 1
        end = k + 1
        while end < len(text) and text[end] in '\r\n': end += 1
        ls = text.rfind('\n', 0, st); start = ls + 1
        text = text[:start] + text[end:]
    return text

s = remove_tr(s, "_('Conntrack')")
s = remove_tr(s, "_('CPU Usage')")
for fn in ('formatCPUUsage', 'ct_bar_html', 'cpu_html'):
    s = remove_func(s, fn)
s = re.sub(r"[ \t]*var (?:conntrack_bar|cpu_bar) = document\.getElementById[\s\S]*?\.innerHTML;\n", '', s)
s = s.replace('status + ppe/cpu/conntrack', 'status + ppe').replace('status + ppe/conntrack', 'status + ppe')
s = re.sub(r"[ \t]*o = s\.option\(form\.ListValue, 'fastpath_mh_eth_hnat_ppenum'[\s\S]*?o\.depends\('fastpath_mh_eth_hnat', '1'\);\n", '', s)
s = re.sub(r"[ \t]*o = s\.option\(form\.ListValue, 'fullcone'[\s\S]*?o\.rmempty = false;\n",
           "\t\t/* Full cone NAT is owned by firewall (sonic-fullcone), not TurboACC. */\n", s)
if s != orig:
    write(FILES['JS'], s); print('[diy]   JS: 行级兜底已执行（有残留块被清除）')
else:
    print('[diy]   JS: 行级兜底无需改动（第一层已全部命中）')

# ---------- 第三层 A0：firewall.config 的 wan zone 两层开关 ----------
# sonic 的 defaults.fullcone 只是全局 gate，还必须在 wan zone 上显式开一次。
WZ = ("config zone\n"
      "\toption name\t\twan\n"
      "\tlist   network\t\t'wan'\n"
      "\tlist   network\t\t'wan6'\n"
      "\toption input\t\tREJECT\n"
      "\toption output\t\tACCEPT\n"
      "\toption forward\t\tREJECT\n"
      "\toption masq\t\t1\n"
      "\toption mtu_fix\t\t1\n")
WZ_ADD = "\toption fullcone\t\t1\n\tlist   fullcone_proto\t'udp'\n"
t = read(FILES['FWCFG'])
if WZ_ADD.strip() not in t:
    if WZ not in t:
        print('[diy] × firewall.config 找不到 wan zone 块，无法添加第二层开关'); sys.exit(1)
    t = t.replace(WZ, WZ + WZ_ADD, 1)
    write(FILES['FWCFG'], t)
    print('[diy]   firewall.config: wan zone 已加 fullcone=1 + fullcone_proto=udp')
else:
    print('[diy]   firewall.config: wan zone 两层开关已存在（幂等）')

# ---------- 第三层 A1/A2：UCD / INIT 的纯插入（第一层已跳过空 old 对）----------
# str.replace('', ...) 会把内容插到文件开头，所以纯插入对必须由这里按锚点落地。
INS = dict((k, [b for a, b in pairs if not a]) for k, pairs in REPL.items())

# A1: uci-defaults/turboacc —— 开机补齐两层开关（仅当选项缺失时）
t = read(FILES['UCD'])
if 'sonic-fullcone：开机默认两层开关' not in t:
    block = INS['UCD'][0]
    anchor = 'rm -f /tmp/luci-indexcache\nexit 0\n'
    if anchor not in t:
        print('[diy] × uci-defaults/turboacc 找不到 exit 0 锚点'); sys.exit(1)
    write(FILES['UCD'], t.replace(anchor, block + anchor, 1))
    print('[diy]   uci-defaults: 已加入开机补齐两层开关（仅缺失才补）')
else:
    print('[diy]   uci-defaults: 开机补齐已存在（幂等）')

# A2: init.d/turboacc —— start_service 末尾后台自愈（不覆盖 boot/start 链）
t = read(FILES['INIT'])
if 'sonic-fullcone 开机自愈' not in t:
    block = INS['INIT'][0]
    anchor = '\techo "prefer-family = IPv4" >> /etc/wgetrc\n}'
    if anchor not in t:
        print('[diy] × init.d/turboacc 找不到 start_service 末尾锚点'); sys.exit(1)
    write(FILES['INIT'], t.replace(anchor,
        '\techo "prefer-family = IPv4" >> /etc/wgetrc\n' + block + '}', 1))
    print('[diy]   init.d/turboacc: 已加入开机自愈（规则 + rpcd）')
else:
    print('[diy]   init.d/turboacc: 开机自愈已存在（幂等）')

# ---------- 第三层 A：libnftnl 加 PKG_FIXUP:=autoreconf ----------
# sonic 的 001 改了 src/Makefile.am，会触发 automake 1.17/1.18 版本不匹配
t = read(LIBMK)
if 'PKG_FIXUP:=autoreconf' not in t:
    anchor = 'include $(INCLUDE_DIR)/package.mk'
    if anchor in t:
        t = t.replace(anchor, 'PKG_FIXUP:=autoreconf\n\n' + anchor, 1)
    else:
        t = 'PKG_FIXUP:=autoreconf\n\n' + t
    write(LIBMK, t)
    print('[diy]   libnftnl: 已插入 PKG_FIXUP:=autoreconf')
else:
    print('[diy]   libnftnl: PKG_FIXUP 已存在')

# ---------- 第三层 B：sonic 补丁 hunk 计数校验 ----------
def hunk_problems(path):
    s = read(path).splitlines(); probs = []; cur = None
    def finish(c):
        r = []
        if c['o'] != c['oc']: r.append("hunk@%d old %d/%d" % (c['line'], c['o'], c['oc']))
        if c['n'] != c['nc']: r.append("hunk@%d new %d/%d" % (c['line'], c['n'], c['nc']))
        return r
    for i, l in enumerate(s, 1):
        m = re.match(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', l)
        if m:
            if cur: probs += finish(cur)
            cur = {'line': i, 'oc': int(m.group(2) or 1), 'nc': int(m.group(4) or 1), 'o': 0, 'n': 0}
            continue
        if cur:
            if l.startswith(('--- ', '+++ ', 'diff ', 'Index: ')):
                probs += finish(cur); cur = None; continue
            if l.startswith('\\'): continue
            if l.startswith('+'): cur['n'] += 1
            elif l.startswith('-'): cur['o'] += 1
            elif l.startswith(' ') or l == '': cur['o'] += 1; cur['n'] += 1
            else:
                probs += finish(cur); cur = None
    if cur: probs += finish(cur)
    return probs

malformed = []
for p in SONIC_FILES:
    if not os.path.isfile(p):
        malformed.append('缺失 ' + p)
    else:
        for x in hunk_problems(p): malformed.append(os.path.basename(p) + ': ' + x)
if malformed:
    print('[diy] × sonic 补丁格式异常:'); [print('        ' + x) for x in malformed]
    sys.exit(1)
print('[diy]   sonic 补丁 hunk 计数校验通过（10 个文件）')

# ---------- 第三层 C：内核补丁冲突预检（尽力而为）----------
core = ['net/netfilter/nf_nat_core.c', 'include/net/netfilter/nf_conntrack.h',
        'net/netfilter/nft_masq.c', 'net/netfilter/xt_MASQUERADE.c',
        'include/uapi/linux/netfilter/nf_nat.h']
clash = []
patches = []
for d in ('target/linux/generic/hack-6.6', 'target/linux/generic/pending-6.6', 'target/linux/generic/backport-6.6'):
    if os.path.isdir(d):
        patches += [os.path.join(d, f) for f in os.listdir(d) if f.endswith('.patch')]
for p in patches:
    if os.path.abspath(p) in [os.path.abspath(x) for x in SONIC_FILES]: continue
    try: body = read(p)
    except Exception: continue
    for c in core:
        if ('--- a/' + c) in body or ('+++ b/' + c) in body:
            clash.append(os.path.basename(p) + ' -> ' + c)
if clash:
    print('[diy] ! 内核补丁冲突预检（可能与 984/986 改同一文件，注意 kernel prepare 日志）:')
    for x in sorted(set(clash))[:12]: print('        ' + x)
else:
    print('[diy]   内核补丁冲突预检：未发现其它补丁改同一文件')

# ---------- 第三层 D：把 fullcone 开关放回「网络 → 防火墙」页面 ----------
# 只写【未跟踪】补丁文件到包的 patches/ 目录，编译阶段由 OpenWrt 自动应用；
# 绝不修改 feeds/luci 里已跟踪的文件（否则 workflow 后续的 git pull 会冲突）。
LUCI_PKG = 'feeds/luci/applications/luci-app-firewall'
ZONES = os.path.join(LUCI_PKG, 'htdocs/luci-static/resources/view/firewall/zones.js')
OFFICIAL = '/tmp/sonic_luci.patch'
LUCI_TARGET = os.path.join(LUCI_PKG, 'patches', '001-add-fullcone-options.patch')
ZREL = 'htdocs/luci-static/resources/view/firewall/zones.js'

def luci_dry_run(patch_path):
    try:
        with open(patch_path, 'rb') as f:
            log = open('/tmp/diy_luci_dry.log', 'wb')
            r = subprocess.call(['patch', '-p1', '--dry-run', '--batch', '--fuzz=3'],
                                stdin=f, cwd=LUCI_PKG, stdout=log,
                                stderr=subprocess.STDOUT)
            log.close()
        return r == 0
    except Exception:
        return False

def build_adaptive(zlines, ins_groups, needles):
    """按锚点实际行号生成单上下文补丁，绕开官方补丁的行号/上下文差异。"""
    if len(ins_groups) != len(needles):
        return None
    out = ['--- a/' + ZREL, '+++ b/' + ZREL]
    for needle, ins in zip(needles, ins_groups):
        idx = next((i for i, l in enumerate(zlines) if needle in l), None)
        if idx is None or not ins:
            return None
        n = idx + 1
        out.append('@@ -%d,1 +%d,%d @@' % (n, n, 1 + len(ins)))
        out.append(' ' + zlines[idx])
        for x in ins:
            out.append('+' + x)
    return '\n'.join(out) + '\n'

luci_placed = False
if os.path.isfile(ZONES) and os.path.isfile(OFFICIAL):
    if luci_dry_run(OFFICIAL):
        os.makedirs(os.path.dirname(LUCI_TARGET), exist_ok=True)
        shutil.copyfile(OFFICIAL, LUCI_TARGET)
        luci_placed = True
        print('[diy]   LuCI: sonic 官方补丁 dry-run 通过，已放入 patches/')
    else:
        print('[diy]   LuCI: 官方补丁 hunk 不匹配，改按锚点生成自适应补丁')
        try:
            groups, cur = [], None
            for l in read(OFFICIAL).splitlines():
                if l.startswith('@@'):
                    if cur is not None: groups.append(cur)
                    cur = []
                    continue
                if l.startswith(('--- ', '+++ ', 'diff ', 'From:', 'Date:', 'Subject:')):
                    if cur is not None: groups.append(cur)
                    cur = None
                    continue
                if cur is not None and l.startswith('+'):
                    cur.append(l[1:])
            if cur: groups.append(cur)
            needles = ["form.Flag, 'drop_invalid'", "form.Flag, 'mtu_fix'",
                       "form.Flag, 'masq_allow_invalid'"]
            adaptive = build_adaptive(read(ZONES).splitlines(), groups, needles)
            if adaptive is None:
                print('[diy]   LuCI: 找不到 3 个锚点，跳过图形开关')
            else:
                write('/tmp/sonic_luci_adaptive.patch', adaptive)
                if luci_dry_run('/tmp/sonic_luci_adaptive.patch'):
                    os.makedirs(os.path.dirname(LUCI_TARGET), exist_ok=True)
                    shutil.copyfile('/tmp/sonic_luci_adaptive.patch', LUCI_TARGET)
                    luci_placed = True
                    print('[diy]   LuCI: 自适应补丁 dry-run 通过，已放入 patches/')
                else:
                    print('[diy]   LuCI: 自适应补丁仍未通过，跳过图形开关')
        except Exception as e:
            print('[diy]   LuCI: 自适应生成异常 (%s)，跳过图形开关' % e)
else:
    print('[diy]   LuCI: feed 或补丁文件未就绪，跳过图形开关')

# ---------- 第四层：强制自检 ----------
js   = read(FILES['JS']);  ini = read(FILES['INIT']); ucd = read(FILES['UCD'])
mk   = read(FILES['MK']);  rp  = read(FILES['RPCD']); cfg = read(FILES['FWCFG'])
libm = read(LIBMK)
conf = read(CFG) if os.path.isfile(CFG) else ''
fw4p = read('package/network/config/firewall4/patches/001-sonic-fullcone.patch')

# wan zone 段（用于判定第二层开关确实落在 wan 而不是别的 zone）
wz = cfg[cfg.find("option name\t\twan"):]
wz = wz[:wz.find('config ') if wz.find('config ') > 0 else len(wz)]

# v7: 两个 shell 脚本必须语法正确（开机要执行，不能只做字符串自检）
sh_ok = True
for _f in (FILES['UCD'], FILES['INIT']):
    try:
        sh_ok &= (subprocess.call(['sh', '-n', _f],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL) == 0)
    except Exception:
        sh_ok = False

checks = [
 ('682 BCM-NAT 补丁已删', not os.path.exists('target/linux/generic/pending-6.6/682-add-bcm-fullconenat-support.patch')),
 ('旧 fw4 fullcone 补丁已删', not os.path.exists('package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch')),
 ('旧 fw3 fullconenat.patch 已删', not os.path.exists('package/network/config/firewall/patches/fullconenat.patch')),
 ('4 个内核补丁到位 (984-987)', all(os.path.exists(os.path.join(HACK, f)) for f in
    ['984-add-sonic-fullcone-support.patch','985-add-sonic-fullcone-to-ipt.patch',
     '986-add-sonic-fullcone-to-nft.patch','987-sonic-fullcone-fix-races-and-drops.patch'])),
 ('sonic fw4/fw3 补丁到位', all(os.path.exists(p) for p in SONIC_FILES[-2:])),
 ('nftables 002/003 与 libnftnl 001 到位', all(os.path.exists(p) for p in SONIC_FILES[5:8])),
 ('iptables 901 到位', os.path.exists(SONIC_FILES[4])),
 ('fw4 自检前 modprobe nft_masq 保险在位', 'modprobe nft_masq' in fw4p),
 ('libnftnl PKG_FIXUP:=autoreconf 在位', 'PKG_FIXUP:=autoreconf' in libm),
 ('.config 已撤掉 kmod-nft-fullcone', 'CONFIG_PACKAGE_kmod-nft-fullcone=y' not in conf),
 ('.config 已关 kmod-ipt-fullconenat', 'CONFIG_PACKAGE_kmod-ipt-fullconenat=y' not in conf),
 ('.config 未写入 bind_rate', 'fastpath_mh_eth_hnat_bind_rate' not in conf),
 ('firewall defaults fullcone=1 (全局 gate)', bool(re.search(r'^config defaults[\s\S]*?^\s*option\s+fullcone\s+1', cfg, re.M))),
 ('wan zone fullcone=1 (第二层 gate)', bool(re.search(r'^\s*option\s+fullcone\s+1', wz, re.M))),
 ('wan zone 仅 UDP (降低与 HNAT 交互面)', "list   fullcone_proto\t'udp'" in wz),
 ('Makefile 无 kmod-nft-fullcone 依赖', 'kmod-nft-fullcone' not in mk and 'kmod-ipt-fullconenat' not in mk),
 ('rpcd 改为 sonic 规则探测', 'sonic_fullcone' in rp and 'nft_fullcone/refcnt' not in rp),
 ('TurboACC fullcone 下拉已移除', "form.ListValue, 'fullcone'" not in js),
 ('CPU 占用显示已移除', 'CPU Usage' not in js and 'formatCPUUsage' not in js),
 ('活动连接(Conntrack)显示已移除', "_('Conntrack')" not in js and 'ct_bar_html' not in js),
 ('ppenum 下拉与幽灵键已清理', 'fastpath_mh_eth_hnat_ppenum' not in js and 'fastpath_mh_eth_hnat_ppenum' not in ucd),
 ('PPE Bind Entrys 进度条保留', 'ppe_bar_html' in js and 'Bind Entrys' in js),
 ('bind_rate 下拉保留', 'fastpath_mh_eth_hnat_bind_rate' in js),
 ('init.d 不写 nat_mode', 'echo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode' not in ini),
 ('init.d 不重载 firewall（解耦）', '/etc/init.d/firewall restart' not in ini),
 ('init.d bind_rate 仍为 30', '"30"' in ini),
 ('uci-defaults 不再写 fullcone', 'turboacc.config.fullcone' not in ucd),
 ('TurboACC 状态仍认 nft 规则', '/usr/sbin/nft list ruleset' in rp),
 ('JS sonic 状态显示映射已就位', 'formatStatType' in js and 'SONiC Fullcone (UDP)' in js),
 ('JS renderStatus 防空（避免整栏空白）', 'stat && stat.type' in js),
 ('fullcone 初次渲染不再卡 Collecting data', "E('td', { 'id': 'fullcone_state' },\n\t\t\t\t\t\trenderStatus(svc_stats)[1])" in js),
 ('rpcd 使用 /usr/sbin/nft 绝对路径', '/usr/sbin/nft' in rp),
 ('uci-defaults 开机补齐两层开关（保留配置也不怕）', 'FW_WAN' in ucd and 'firewall.@defaults[0].fullcone' in ucd and 'fullcone_proto=udp' in ucd),
 ('uci-defaults 仅缺失才补（不覆盖用户显式 0）', '[ -z "$(uci -q get firewall.@defaults[0].fullcone)" ]' in ucd),
 ('init.d 开机自愈块在位', 'sonic-fullcone 开机自愈' in ini and '/etc/init.d/firewall reload' in ini and '/etc/init.d/rpcd restart' in ini),
 ('自愈不覆盖 boot/start 启动链', 'boot()' not in ini),
 ('UCD/INIT shell 语法通过', sh_ok),
]

if luci_placed:
    print('[diy] ✓ 防火墙页面 Fullcone 开关补丁在位')
else:
    print('[diy] ! 防火墙页面图形开关未放置（feed 未就绪或版本不匹配）；')
    print('[diy]   fullcone 功能不受影响，仍由 /etc/config/firewall 两层开关控制')

bad = 0
print('[diy] ===== 强制自检 =====')
for name, ok in checks:
    print('[diy] %s %s' % ('✓' if ok else '×', name))
    if not ok: bad += 1
if bad:
    print('[diy] ×× %d 项未达标，终止编译（避免产出半成品固件）' % bad)
    sys.exit(1)
print('[diy] ✓ 全部 %d 项通过' % len(checks))
PYEOF
python3 /tmp/diy_transform.py || exit 1

echo
echo "[diy] 提醒：本版已内置【开机默认补齐 + 自愈】，刷完无需任何 SSH 命令。"
echo "      uci-defaults 在选项缺失时补两层开关 + udp；init.d/turboacc 开机"
echo "      12 秒后自检规则与 rpcd，异常时各 reload 一次（正常开机零干预）。"
echo "[diy] 提醒：仍建议刷机不勾『保留配置』（出厂值本来就是对的）；"
echo "      即便勾了，补齐逻辑也会让 fullcone 规则自动生成。"
echo "[diy] 提醒：本版把开关放回『网络 → 防火墙』页面（常规设置总开关 + 区域编辑）；"
echo "      若日志显示 LuCI 补丁被跳过，功能仍可用 UCI 配置，只是页面没有复选框。"
echo "[diy] 提醒：TurboACC 状态栏应显示绿色『SONiC Fullcone (UDP)』；"
echo "      若仍是旧文字，执行 rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 后强刷页面。"
echo "[diy] 提醒：sonic 内核补丁(984/986)在这棵 mt798x 6.6.162 树上未经验证，"
echo "      若编译在 kernel prepare 阶段报 Patch failed，把日志贴出来即可。"
echo "[diy] 提醒：刷后验证 nft list ruleset | grep fullcone、BIND_PPE0 曲线、"
echo "      Turbo ACC 状态栏应显示 sonic_fullcone。"

exit 0
