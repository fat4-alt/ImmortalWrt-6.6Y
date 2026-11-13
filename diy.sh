#!/bin/sh
# Modify default theme
[ -f feeds/luci/collections/luci/Makefile ] && \
  sed -i 's/luci-theme-argon/luci-theme-bootstrap/g' feeds/luci/collections/luci/Makefile

# Modify hostname
[ -f package/base-files/files/bin/config_generate ] && \
  sed -i 's/ImmortalWrt/WMYWrt/g' package/base-files/files/bin/config_generate

CFG="${GITHUB_WORKSPACE}/.config"
if [ -f "$CFG" ]; then
  if grep -q '^# CONFIG_PACKAGE_kmod-nft-fullcone is not set' "$CFG"; then
    sed -i 's|^# CONFIG_PACKAGE_kmod-nft-fullcone is not set|CONFIG_PACKAGE_kmod-nft-fullcone=y|' "$CFG"
  elif ! grep -q '^CONFIG_PACKAGE_kmod-nft-fullcone=y' "$CFG"; then
    echo 'CONFIG_PACKAGE_kmod-nft-fullcone=y' >> "$CFG"
  fi
  echo "[diy] kmod-nft-fullcone=y 已写入 .config"
else
  echo "[diy] 警告：找不到 $CFG，靠 Makefile 的 +依赖让 make defconfig 自动选中"
fi

# ---- 应用 Turbo ACC / FULLCONENAT 补丁 ----
JS="package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js"
if grep -q "o.value('1', _('FULLCONENAT'))" "$JS" 2>/dev/null; then
  echo "[diy] 补丁已存在，跳过"
else
  cat > /tmp/fullconenat.patch <<'PATCH_EOF'
--- a/package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js
+++ b/package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js
@@ -312,7 +312,8 @@
 
 		o = s.option(form.ListValue, 'fullcone', _('Full cone NAT'),
 			_('Full cone NAT (NAT1) can improve gaming performance effectively.'));
-		o.value('0', _('Disable'))
+		o.value('0', _('Disable'));
+		o.value('1', _('FULLCONENAT'));
 		o.value('2', _('Boardcom_FULLCONE_NAT'));
 		o.default = '0';
 		o.rmempty = false;
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc
@@ -65,7 +65,40 @@
 
 	local fullcone
 	config_get "fullcone" "config" "fullcone" "2"
-	echo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode
+
+	# fullcone: 0=Disable / 1=FULLCONENAT / 2=Boardcom_FULLCONE_NAT
+	# The two implementations are mutually exclusive: always shut down the
+	# other one first, otherwise conntrack/NAT is processed twice.
+	case "$fullcone" in
+	"1")
+		# Rule-based fullcone: fw4 'fullcone' expression or fw3 xt_FULLCONENAT.
+		# Needs kmod-nft-fullcone; fw4 silently drops the option when the
+		# expression is missing, so the Makefile dependency is mandatory.
+		echo 0 > /proc/sys/net/netfilter/nf_conntrack_nat_mode
+		# Load exactly ONE implementation before firewall reloads the ruleset.
+		# Loading xt_FULLCONENAT as well is useless under fw4 and makes
+		# getFullConeStat / conntrack event notifiers ambiguous.
+		if [ -x /usr/sbin/nft ]; then
+			lsmod | grep -q "nft_fullcone" || modprobe "nft_fullcone" 2>"/dev/null"
+		else
+			lsmod | grep -q "xt_FULLCONENAT" || modprobe "xt_FULLCONENAT" 2>"/dev/null"
+		fi
+		uci -q set "firewall.@defaults[0].fullcone"="1"
+		uci -q set "firewall.@defaults[0].fullcone6"="0"
+		uci -q commit "firewall"
+		;;
+	"2")
+		# Kernel global mode: any non-zero value enables bcm_nat fullcone.
+		echo 2 > /proc/sys/net/netfilter/nf_conntrack_nat_mode
+		uci -q set "firewall.@defaults[0].fullcone"="0"
+		uci -q commit "firewall"
+		;;
+	*)
+		echo 0 > /proc/sys/net/netfilter/nf_conntrack_nat_mode
+		uci -q set "firewall.@defaults[0].fullcone"="0"
+		uci -q commit "firewall"
+		;;
+	esac
 
 	local tcpcca
 	config_get "tcpcca" "config" "tcpcca" "cubic"
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc
@@ -24,7 +24,23 @@
 	uci -q set "turboacc.config.fastpath"="none"
 fi
 
-uci -q set "turboacc.config.fullcone"="2"
+# fullcone: 0=Disable / 1=FULLCONENAT / 2=Boardcom_FULLCONE_NAT
+# Only write a default when the user has not chosen yet, then pick a mode
+# this image can actually run. Without nft_fullcone.ko, fw4 silently drops
+# the fullcone option, so fall back to the always-available kernel mode.
+if [ -z "$(uci -q get turboacc.config.fullcone)" ]; then
+	if [ -e "/lib/modules/$kernel_ver/nft_fullcone.ko" ]; then
+		uci -q set "turboacc.config.fullcone"="1"
+	else
+		uci -q set "turboacc.config.fullcone"="2"
+	fi
+fi
+
+# Reject out-of-range values written by hand.
+case "$(uci -q get turboacc.config.fullcone)" in
+	0|1|2) ;;
+	*) uci -q set "turboacc.config.fullcone"="0" ;;
+esac
 
 uci -q commit "turboacc"
 
--- a/package/mtk/applications/luci-app-turboacc-mtk/Makefile
+++ b/package/mtk/applications/luci-app-turboacc-mtk/Makefile
@@ -13,7 +13,7 @@
 	+kmod-nft-socket +kmod-nft-tproxy +kmod-nft-nat +kmod-inet-diag \
 	+kmod-ipt-nat6 +kmod-ipt-nat +kmod-netlink-diag \
 	+kmod-ipt-physdev +kmod-nf-ipvs +kmod-veth +kmod-wireguard \
-	+kmod-ipt-fullconenat +kmod-fs-btrfs +kmod-bonding \
+	+kmod-ipt-fullconenat +kmod-nft-fullcone +kmod-fs-btrfs +kmod-bonding \
 	@!PACKAGE_luci-app-turboacc
 LUCI_PKGARCH:=all
 
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc
@@ -168,10 +168,13 @@
 	getFullConeStat = {
 		call = function()
 			local fctype
-			if fs.access("/sys/module/xt_FULLCONENAT/refcnt") and
+			if fs.access("/sys/module/nft_fullcone/refcnt") and
+			(readfile("/sys/module/nft_fullcone/refcnt") or "0") ~= "0" then
+				fctype = "FULLCONENAT"
+			elseif fs.access("/sys/module/xt_FULLCONENAT/refcnt") and
 			(readfile("/sys/module/xt_FULLCONENAT/refcnt") or "0") ~= "0" then
 				fctype = "xt_FULLCONENAT"
-			elseif  fs.access("/proc/sys/net/netfilter/nf_conntrack_nat_mode") and
+			elseif fs.access("/proc/sys/net/netfilter/nf_conntrack_nat_mode") and
 				(readfile("/proc/sys/net/netfilter/nf_conntrack_nat_mode") or "0") ~= "0" then
 				fctype = "Boardcom Fullcone"
 			end
PATCH_EOF
  if git apply --check /tmp/fullconenat.patch 2>/dev/null; then
    git apply /tmp/fullconenat.patch
  elif patch -p1 --fuzz=3 --dry-run < /tmp/fullconenat.patch >/dev/null 2>&1; then
    patch -p1 --fuzz=3 < /tmp/fullconenat.patch
  else
    echo "=========================================================="
    echo "[diy] × 补丁没打上（上游源码可能已更新，行号对不上）。"
    echo "      补丁内容已保存在 /tmp/fullconenat.patch，可从编译日志里取回。"
    echo "=========================================================="
    exit 1
  fi
  echo "[diy] ✓ Turbo ACC FULLCONENAT 补丁已应用（5 处）"
fi

# ---- 自检 ----
grep -q 'o.value' "$JS" && grep -q "FULLCONENAT" "$JS" && echo "[diy] ✓ 下拉项已加入"
grep -q 'kmod-nft-fullcone' package/mtk/applications/luci-app-turboacc-mtk/Makefile && echo "[diy] ✓ nft_fullcone 依赖已加入"

exit 0
