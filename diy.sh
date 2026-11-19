#!/bin/sh

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

CFG="${GITHUB_WORKSPACE}/.config"
JS="package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js"
UCD="package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc"
INIT="package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc"
MK="package/mtk/applications/luci-app-turboacc-mtk/Makefile"
NFTMK="package/network/utils/fullconenat-nft/Makefile"
FWCFG="package/network/config/firewall/files/firewall.config"

# ---------------- 1/4 写 .config（bind_rate 一个字都不碰） ----------------
if [ -f "$CFG" ]; then
  # 打开 nft fullcone
  sed -i 's|^# CONFIG_PACKAGE_kmod-nft-fullcone is not set|CONFIG_PACKAGE_kmod-nft-fullcone=y|' "$CFG"
  grep -q '^CONFIG_PACKAGE_kmod-nft-fullcone=y' "$CFG" || \
    echo 'CONFIG_PACKAGE_kmod-nft-fullcone=y' >> "$CFG"
  # 关掉 iptables 版 fullconenat（fw4 用不到 xt target）
  sed -i 's|^CONFIG_PACKAGE_kmod-ipt-fullconenat=y|# CONFIG_PACKAGE_kmod-ipt-fullconenat is not set|' "$CFG"
  sed -i 's|^CONFIG_DEFAULT_kmod-ipt-fullconenat=y|# CONFIG_DEFAULT_kmod-ipt-fullconenat is not set|' "$CFG"
  echo "[diy] ✓ kmod-nft-fullcone=y / kmod-ipt-fullconenat 已关闭"
  echo "[diy] ✓ bind_rate 未写入 .config，UCI 默认 30 保持不变"
else
  echo "[diy] ! 找不到 $CFG，靠 Makefile 依赖让 make defconfig 自动选中"
fi

# ---------------- 2/4 去除 Broadcom / BCM-NAT 内核实现 ----------------
# 该补丁提供 nf_conntrack_nat_mode sysctl 与 BCM-NAT helper（模式 2）。
# 删除后内核不再有这套机制；TurboACC 也会同步去掉写 sysctl 的代码。
rm -f "target/linux/generic/pending-6.6/682-add-bcm-fullconenat-support.patch"
echo "[diy] ✓ 已删除 682-add-bcm-fullconenat-support.patch"

# ---------------- 3/4 确保 /etc/config/firewall 默认开启 fullcone ----------------
# 6.6 树的 firewall.config 出厂已是 1，这里做幂等兜底，防止上游改回 0。
if [ -f "$FWCFG" ]; then
  sed -i 's|option fullcone[[:space:]]*0|option fullcone\t\t1|' "$FWCFG"
  if grep -qE '^[[:space:]]*option[[:space:]]+fullcone[[:space:]]+1' "$FWCFG"; then
    echo "[diy] ✓ firewall.config: option fullcone 1"
  else
    echo "[diy] × firewall.config 缺少 option fullcone 1，请检查上游源码"; exit 1
  fi
fi

# ---------------- 4/4 应用补丁（6 处源码改动） ----------------
if ! grep -q "form.ListValue, 'fullcone'" "$JS" 2>/dev/null; then
  echo "[diy] 补丁已应用过，跳过"
else
  cat > /tmp/fullcone-firewall-only.patch <<'PATCH_EOF'
--- a/package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js
+++ b/package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js
@@ -310,12 +310,7 @@
 		o.default = 2;
 		o.depends('fastpath_mh_eth_hnat', '1');
 
-		o = s.option(form.ListValue, 'fullcone', _('Full cone NAT'),
-			_('Full cone NAT (NAT1) can improve gaming performance effectively.'));
-		o.value('0', _('Disable'))
-		o.value('2', _('Boardcom_FULLCONE_NAT'));
-		o.default = '0';
-		o.rmempty = false;
+		/* Full cone NAT is owned by firewall (option fullcone), not TurboACC. */
 
 		o = s.option(form.ListValue, 'tcpcca', _('TCP CCA'),
 			_('TCP congestion control algorithm.'));
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc
@@ -63,17 +63,17 @@
 		;;
 	esac
 
-	local fullcone
-	config_get "fullcone" "config" "fullcone" "2"
-	echo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode
+	# Full cone NAT is owned by firewall4 (/etc/config/firewall: option fullcone).
+	# Do NOT touch nf_conntrack_nat_mode here (Broadcom/BCM-NAT removed) and
+	# do NOT reload the firewall below: rebuilding the ruleset invalidates
+	# bound HNAT/PPE entries and causes throughput fluctuation.
 
 	local tcpcca
 	config_get "tcpcca" "config" "tcpcca" "cubic"
 	sysctl -w net.ipv4.tcp_congestion_control="$tcpcca" >"/dev/null"
 
-	# Cleanup firewall rules
-	uci -q commit "firewall"
-	/etc/init.d/firewall restart >"/dev/null" 2>&1
+	# The firewall ruleset is managed by firewall4 itself; TurboACC must not
+	# commit or reload it here.
 
 	# Save Memory
     echo 4096 > /proc/sys/vm/min_free_kbytes
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc
@@ -24,7 +24,8 @@
 	uci -q set "turboacc.config.fastpath"="none"
 fi
 
-uci -q set "turboacc.config.fullcone"="2"
+# Full cone NAT is configured in /etc/config/firewall (option fullcone 1).
+# TurboACC no longer owns any fullcone setting.
 
 uci -q commit "turboacc"
 
--- a/package/mtk/applications/luci-app-turboacc-mtk/Makefile
+++ b/package/mtk/applications/luci-app-turboacc-mtk/Makefile
@@ -13,7 +13,7 @@
 	+kmod-nft-socket +kmod-nft-tproxy +kmod-nft-nat +kmod-inet-diag \
 	+kmod-ipt-nat6 +kmod-ipt-nat +kmod-netlink-diag \
 	+kmod-ipt-physdev +kmod-nf-ipvs +kmod-veth +kmod-wireguard \
-	+kmod-ipt-fullconenat +kmod-fs-btrfs +kmod-bonding \
+	+kmod-nft-fullcone +kmod-fs-btrfs +kmod-bonding \
 	@!PACKAGE_luci-app-turboacc
 LUCI_PKGARCH:=all
 
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc
@@ -168,12 +168,9 @@
 	getFullConeStat = {
 		call = function()
 			local fctype
-			if fs.access("/sys/module/xt_FULLCONENAT/refcnt") and
-			(readfile("/sys/module/xt_FULLCONENAT/refcnt") or "0") ~= "0" then
-				fctype = "xt_FULLCONENAT"
-			elseif  fs.access("/proc/sys/net/netfilter/nf_conntrack_nat_mode") and
-				(readfile("/proc/sys/net/netfilter/nf_conntrack_nat_mode") or "0") ~= "0" then
-				fctype = "Boardcom Fullcone"
+			if fs.access("/sys/module/nft_fullcone/refcnt") and
+			(readfile("/sys/module/nft_fullcone/refcnt") or "0") ~= "0" then
+				fctype = "nft_fullcone"
 			end
 			print(json.stringify({ type = fctype }))
 		end
--- a/package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch
+++ b/package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch
@@ -28,7 +28,7 @@
  #	option disable_ipv6	1
 +	option flow_offloading	0
 +	option flow_offloading_hw	0
-+	option fullcone		0
++	option fullcone		1
 +	option fullcone6	0
  
  config zone
@@ -97,6 +97,8 @@
  }
  
 +function nft_try_fullcone() {
++	/* Make sure the fullcone expr is registered before probing. */
++	system("/sbin/modprobe nft_fullcone 2>/dev/null");
 +	let nft_test =
 +		'add table inet fw4-fullcone-test; ' +
 +		'add chain inet fw4-fullcone-test dstnat { ' +
PATCH_EOF
  if git apply --check /tmp/fullcone-firewall-only.patch 2>/dev/null; then
    git apply /tmp/fullcone-firewall-only.patch
  elif patch -p1 --fuzz=3 --dry-run < /tmp/fullcone-firewall-only.patch >/dev/null 2>&1; then
    patch -p1 --fuzz=3 < /tmp/fullcone-firewall-only.patch
  else
    echo "=========================================================="
    echo "[diy] × 补丁没打上（上游源码行号变了），补丁留在 /tmp/fullcone-firewall-only.patch"
    echo "=========================================================="
    exit 1
  fi
  echo "[diy] ✓ 补丁已应用（6 处）"
fi

# ---------------- 自检 ----------------
grep -q "form.ListValue, 'fullcone'" "$JS" && echo "[diy] × TurboACC 仍有 fullcone 下拉" || echo "[diy] ✓ TurboACC 下拉已移除"
grep -q 'kmod-nft-fullcone' "$MK" && echo "[diy] ✓ 依赖已换成 kmod-nft-fullcone"
grep -q 'echo.*nf_conntrack_nat_mode' "$INIT" && echo "[diy] × init.d 仍写 sysctl" || echo "[diy] ✓ init.d 不再写 nat_mode"
grep -q '/etc/init.d/firewall restart' "$INIT" && echo "[diy] × init.d 仍重载 firewall" || echo "[diy] ✓ init.d 不再重载 firewall（解耦）"
grep -q 'turboacc.config.fullcone' "$UCD" && echo "[diy] × uci-defaults 仍写 fullcone" || echo "[diy] ✓ uci-defaults 不再写 fullcone"
grep -q 'AUTOLOAD:=$(call AutoProbe,nft_fullcone)' "$NFTMK" && echo "[diy] ✓ nft_fullcone 开机 autoload 保留（默认开启的必要条件）"
grep -q 'option fullcone.*1' "$FWCFG" && echo "[diy] ✓ 出厂默认开启"
[ -f "target/linux/generic/pending-6.6/682-add-bcm-fullconenat-support.patch" ] && echo "[diy] × 682 补丁还在" || echo "[diy] ✓ Broadcom 内核补丁已移除"
# bind_rate 自检：只打印，绝不修改
grep -q 'fastpath_mh_eth_hnat_bind_rate.*"30"' "$INIT" && echo "[diy] ✓ bind_rate 仍为 30（未改动）"

echo
echo "[diy] 提醒：刷机时请勿勾选『保留配置』。旧 /etc/config/firewall 里的"
echo "      option fullcone=0 会覆盖新固件默认值；若已保留，刷完执行："
echo "      uci set firewall.@defaults[0].fullcone=1; uci commit firewall; /etc/init.d/firewall restart"

exit 0
