#!/bin/sh
# ============================================================
#  fullcone -> firewall 版  +  custom/ 扁平三文件「只添加，不覆盖」模式
#
#  custom/ 里只有 3 个文件，没有子文件夹：
#   * d.txt  = dts 文件内容       → 写入 target/linux/mediatek/dts/<名字>.dts
#                                    已存在则追加到末尾，不存在则新建；绝不覆盖
#   * f.txt  = filogic.mk 片段    → 追加到 filogic.mk 末尾
#   * n.txt  = 02_network 片段    → 插入到 case $board in 之后
#
#  dts 文件名自动从 f.txt 里的 "DEVICE_DTS := xxx" 推导；
#  也可在 d.txt 首行写 "// FILE: xxx.dts" 显式指定。
#  上游源码文件一律不删行、不覆盖；所有增补带幂等标记，重跑不重复。
#  UI 精简：移除 CPU Usage 显示、以及 init.d 从不读取的 ppenum 下拉。
#  UI 精简：移除「活动连接 / Conntrack」进度条（po 里 msgstr 即「活动连接」）。
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
@@ -49,37 +49,6 @@
 		'class': 'cbi-progressbar',
 		'title': '%s / %s (%d%%)'.format(fv, fm, pc)
 	}, E('div', { 'style': 'width:%.2f%%'.format(pc) }));
-}
-
-function formatCPUUsage(stats) {
-	var text = stats.CPU_USED || '0%';
-
-	if (stats.CPU_CORES_USED) {
-		if (Array.isArray(stats.CPU_CORES_USED)) {
-			if (stats.CPU_CORES_USED.length > 0)
-				text += ' (' + stats.CPU_CORES_USED.join(', ') + ')';
-		} else {
-			var cores = [];
-			for (var core in stats.CPU_CORES_USED) {
-				if (stats.CPU_CORES_USED.hasOwnProperty(core))
-					cores.push(core);
-			}
-			cores.sort(function (a, b) {
-				var na = parseInt(a.replace(/^CPU/i, ''), 10);
-				var nb = parseInt(b.replace(/^CPU/i, ''), 10);
-				return na - nb;
-			});
-			var coreItems = [];
-			for (var i = 0; i < cores.length; i++) {
-				var k = cores[i];
-				coreItems.push(k + ': ' + stats.CPU_CORES_USED[k]);
-			}
-			if (coreItems.length > 0)
-				text += ' (' + coreItems.join(', ') + ')';
-		}
-	}
-
-	return text;
 }
 
 function renderStatus(stats) {
@@ -124,7 +93,7 @@
 		s = m.section(form.TypedSection);
 		s.anonymous = true;
 		s.render = function () {
-			/* ---- single unified poll: status + ppe/cpu/conntrack ---- */
+			/* ---- single unified poll: status + ppe ---- */
 			poll.add(function () {
 				return Promise.all([
 					L.resolveDefault(getFastPathStat(), {}),
@@ -151,29 +120,12 @@
 						}
 					}
 
-					var conntrack_bar = document.getElementById('conntrack_state');
-					if (conntrack_bar)
-						conntrack_bar.innerHTML = E('em', {},
-							progressbar(parseInt(stat.Conntrack_Count), parseInt(stat.Conntrack_Max))
-						).innerHTML;
-
-					var cpu_bar = document.getElementById('cpu_usage_state');
-					if (cpu_bar)
-						cpu_bar.innerHTML = E('em', {}, formatCPUUsage(stat)).innerHTML;
 				});
 			}, 2);
 
 			/* ---- initial render helpers ---- */
 			function ppe_bar_html(stats, idx) {
 				return progressbar(stats['BIND_PPE' + idx], stats['ALL_PPE' + idx]);
-			}
-			function ct_bar_html(stats) {
-				if (!stats.Conntrack_Count) return E('em', {}, _('Collecting data...'));
-				return progressbar(parseInt(stats.Conntrack_Count), parseInt(stats.Conntrack_Max));
-			}
-			function cpu_html(stats) {
-				if (!stats.CPU_USED) return E('em', {}, _('Collecting data...'));
-				return formatCPUUsage(stats);
 			}
 			var hasPPE = ppe_stats.hasOwnProperty('PPE_NUM');
 
@@ -199,14 +151,6 @@
 						svc_stats[2] && svc_stats[2].type
 							? renderStatus(svc_stats)[2]
 							: E('em', {}, _('Collecting data...')))
-				]),
-				E('tr', {}, [
-					E('td', { 'width': '33%' }, _('Conntrack')),
-					E('td', { 'id': 'conntrack_state' }, ct_bar_html(ppe_stats))
-				]),
-				E('tr', {}, [
-					E('td', { 'width': '33%' }, _('CPU Usage')),
-					E('td', { 'id': 'cpu_usage_state' }, cpu_html(ppe_stats))
 				])
 			];
 
@@ -302,20 +246,7 @@
 		o.placeholder = 30;
 		o.depends('fastpath_mh_eth_hnat', '1');
 
-		o = s.option(form.ListValue, 'fastpath_mh_eth_hnat_ppenum', _('Number of HNAT PPE'),
-			_('Apply this setting after reboot.'));
-		o.rmempty = false;
-		o.value(1);
-		o.value(2);
-		o.default = 2;
-		o.depends('fastpath_mh_eth_hnat', '1');
-
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
@@ -63,17 +63,18 @@
 		;;
 	esac
 
-	local fullcone
-	config_get "fullcone" "config" "fullcone" "2"
-	echo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode
+	# Full cone NAT is owned by firewall4 (/etc/config/firewall: option fullcone).
+	# Do NOT touch nf_conntrack_nat_mode here (Broadcom/BCM-NAT removed) and
+	# do NOT reload the firewall below: rebuilding the ruleset invalidates
+	# bound HNAT/PPE entries and causes throughput fluctuation.
+	# (kept the same line count as upstream to stay patch-friendly)
 
 	local tcpcca
 	config_get "tcpcca" "config" "tcpcca" "cubic"
 	sysctl -w net.ipv4.tcp_congestion_control="$tcpcca" >"/dev/null"
 
-	# Cleanup firewall rules
-	uci -q commit "firewall"
-	/etc/init.d/firewall restart >"/dev/null" 2>&1
+	# The firewall ruleset is managed by firewall4 itself; TurboACC must not
+	# commit or reload it here. (line count preserved)
 
 	# Save Memory
     echo 4096 > /proc/sys/vm/min_free_kbytes
--- a/package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc
+++ b/package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc
@@ -9,7 +9,6 @@
 	uci -q set "turboacc.config.fastpath_mh_eth_hnat_v6"="1"
 	uci -q set "turboacc.config.fastpath_mh_eth_hnat_macvlan"="0"
 	uci -q set "turboacc.config.fastpath_mh_eth_hnat_bind_rate"="30"
-	uci -q set "turboacc.config.fastpath_mh_eth_hnat_ppenum"="2"
 elif [ -e "/lib/modules/$kernel_ver/fast-classifier.ko" ]; then
 	uci -q set "turboacc.config.fastpath"="fast_classifier"
 	uci -q set "turboacc.config.fastpath_fc_br"="1"
@@ -24,7 +23,8 @@
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
@@ -108,7 +108,7 @@
 +			'fullcone; ' +
 +		'}; ';
 +	let cmd = sprintf("/usr/sbin/nft -c '%s' 2>/dev/null", replace(nft_test, "'", "'\\''"));
-+	let ok = system(cmd) == 0;
++	system("/sbin/modprobe nft_fullcone 2>/dev/null"); let ok = system(cmd) == 0;
 +	if (!ok) {
 +		warn("nft_try_fullcone: cmd "+ cmd + "\n");
 +	}
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
# 防呆：往 firewall4 补丁里插行却不同步改 hunk 头的 +25，编译会报
# "malformed patch at line 121:  return {"。这里确认补丁格式未被破坏。
FWP="package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
grep -q '^@@ -489,6 +491,25 @@' "$FWP" && echo "[diy] ✓ fw4 补丁 hunk 计数未破坏" || echo "[diy] × fw4 补丁 hunk 计数异常"
grep -q 'modprobe nft_fullcone.*let ok = system(cmd)' "$FWP" && echo "[diy] ✓ 自检前 modprobe 保险在位（等长合并）" || echo "[diy] × modprobe 保险缺失"
[ -f "target/linux/generic/pending-6.6/682-add-bcm-fullconenat-support.patch" ] && echo "[diy] × 682 补丁还在" || echo "[diy] ✓ Broadcom 内核补丁已移除"
# bind_rate 自检：只打印，绝不修改
grep -q 'fastpath_mh_eth_hnat_bind_rate.*"30"' "$INIT" && echo "[diy] ✓ bind_rate 仍为 30（未改动）"
grep -q 'CPU Usage' "$JS" && echo "[diy] × 仍有 CPU Usage 显示" || echo "[diy] ✓ CPU 占用显示已移除"
grep -q 'formatCPUUsage\|cpu_usage_state\|cpu_html' "$JS" && echo "[diy] × 仍有 CPU 相关死代码" || echo "[diy] ✓ CPU 相关代码清理干净"
grep -q 'fastpath_mh_eth_hnat_ppenum' "$JS" && echo "[diy] × 仍有 ppenum 下拉" || echo "[diy] ✓ ppenum 下拉已移除（init.d 未读取，确认无用）"
grep -q 'fastpath_mh_eth_hnat_ppenum' "$UCD" && echo "[diy] × uci-defaults 仍写 ppenum 幽灵键" || echo "[diy] ✓ ppenum 幽灵键已清理"
grep -q "_('Conntrack')" "$JS" && echo "[diy] × 仍有活动连接(Conntrack)显示" || echo "[diy] ✓ 活动连接显示已移除"
grep -q 'conntrack_state\|ct_bar_html\|Conntrack_Count' "$JS" && echo "[diy] × 仍有 Conntrack 相关死代码" || echo "[diy] ✓ Conntrack 前端代码清理干净"

echo
echo "[diy] 提醒：刷机时请勿勾选『保留配置』。旧 /etc/config/firewall 里的"
echo "      option fullcone=0 会覆盖新固件默认值；若已保留，刷完执行："
echo "      uci set firewall.@defaults[0].fullcone=1; uci commit firewall; /etc/init.d/firewall restart"

exit 0
