#!/bin/sh

# Modify default IP
# sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# Modify default theme
sed -i 's/luci-theme-argon/luci-theme-bootstrap/g' feeds/luci/collections/luci/Makefile

# Modify hostname
sed -i 's/ImmortalWrt/FZSWrt/g' package/base-files/files/bin/config_generate

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


rm -f "target/linux/generic/pending-6.6/682-add-bcm-fullconenat-support.patch"
echo "[diy] ✓ 已删除 682-add-bcm-fullconenat-support.patch"


if [ -f "$FWCFG" ]; then
  sed -i 's|option fullcone[[:space:]]*0|option fullcone\t\t1|' "$FWCFG"
  if grep -qE '^[[:space:]]*option[[:space:]]+fullcone[[:space:]]+1' "$FWCFG"; then
    echo "[diy] ✓ firewall.config: option fullcone 1"
  else
    echo "[diy] × firewall.config 缺少 option fullcone 1，请检查上游源码"; exit 1
  fi
fi


cat > /tmp/diy_transform.py <<'PYEOF'
# -*- coding: utf-8 -*-
import os, re, sys

FILES = {
 'JS':   'package/mtk/applications/luci-app-turboacc-mtk/htdocs/luci-static/resources/view/turboacc.js',
 'INIT': 'package/mtk/applications/luci-app-turboacc-mtk/root/etc/init.d/turboacc',
 'UCD':  'package/mtk/applications/luci-app-turboacc-mtk/root/etc/uci-defaults/turboacc',
 'MK':   'package/mtk/applications/luci-app-turboacc-mtk/Makefile',
 'RPCD': 'package/mtk/applications/luci-app-turboacc-mtk/root/usr/libexec/rpcd/luci.turboacc',
 'FWP':  'package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch',
}

REPL = {
    'JS': [
        ("function formatCPUUsage(stats) {\n\tvar text = stats.CPU_USED || '0%';\n\n\tif (stats.CPU_CORES_USED) {\n\t\tif (Array.isArray(stats.CPU_CORES_USED)) {\n\t\t\tif (stats.CPU_CORES_USED.length > 0)\n\t\t\t\ttext += ' (' + stats.CPU_CORES_USED.join(', ') + ')';\n\t\t} else {\n\t\t\tvar cores = [];\n\t\t\tfor (var core in stats.CPU_CORES_USED) {\n\t\t\t\tif (stats.CPU_CORES_USED.hasOwnProperty(core))\n\t\t\t\t\tcores.push(core);\n\t\t\t}\n\t\t\tcores.sort(function (a, b) {\n\t\t\t\tvar na = parseInt(a.replace(/^CPU/i, ''), 10);\n\t\t\t\tvar nb = parseInt(b.replace(/^CPU/i, ''), 10);\n\t\t\t\treturn na - nb;\n\t\t\t});\n\t\t\tvar coreItems = [];\n\t\t\tfor (var i = 0; i < cores.length; i++) {\n\t\t\t\tvar k = cores[i];\n\t\t\t\tcoreItems.push(k + ': ' + stats.CPU_CORES_USED[k]);\n\t\t\t}\n\t\t\tif (coreItems.length > 0)\n\t\t\t\ttext += ' (' + coreItems.join(', ') + ')';\n\t\t}\n\t}\n\n\treturn text;\n}\n\n", ''),
        ('\t\t\t/* ---- single unified poll: status + ppe/cpu/conntrack ---- */\n', '\t\t\t/* ---- single unified poll: status + ppe ---- */\n'),
        ("\t\t\t\t\tvar conntrack_bar = document.getElementById('conntrack_state');\n\t\t\t\t\tif (conntrack_bar)\n\t\t\t\t\t\tconntrack_bar.innerHTML = E('em', {},\n\t\t\t\t\t\t\tprogressbar(parseInt(stat.Conntrack_Count), parseInt(stat.Conntrack_Max))\n\t\t\t\t\t\t).innerHTML;\n\n\t\t\t\t\tvar cpu_bar = document.getElementById('cpu_usage_state');\n\t\t\t\t\tif (cpu_bar)\n\t\t\t\t\t\tcpu_bar.innerHTML = E('em', {}, formatCPUUsage(stat)).innerHTML;\n", ''),
        ("\t\t\t}\n\t\t\tfunction ct_bar_html(stats) {\n\t\t\t\tif (!stats.Conntrack_Count) return E('em', {}, _('Collecting data...'));\n\t\t\t\treturn progressbar(parseInt(stats.Conntrack_Count), parseInt(stats.Conntrack_Max));\n\t\t\t}\n\t\t\tfunction cpu_html(stats) {\n\t\t\t\tif (!stats.CPU_USED) return E('em', {}, _('Collecting data...'));\n\t\t\t\treturn formatCPUUsage(stats);\n", ''),
        ("\t\t\t\t]),\n\t\t\t\tE('tr', {}, [\n\t\t\t\t\tE('td', { 'width': '33%' }, _('Conntrack')),\n\t\t\t\t\tE('td', { 'id': 'conntrack_state' }, ct_bar_html(ppe_stats))\n\t\t\t\t]),\n\t\t\t\tE('tr', {}, [\n\t\t\t\t\tE('td', { 'width': '33%' }, _('CPU Usage')),\n\t\t\t\t\tE('td', { 'id': 'cpu_usage_state' }, cpu_html(ppe_stats))\n", ''),
        ("\t\to = s.option(form.ListValue, 'fastpath_mh_eth_hnat_ppenum', _('Number of HNAT PPE'),\n\t\t\t_('Apply this setting after reboot.'));\n\t\to.rmempty = false;\n\t\to.value(1);\n\t\to.value(2);\n\t\to.default = 2;\n\t\to.depends('fastpath_mh_eth_hnat', '1');\n\n\t\to = s.option(form.ListValue, 'fullcone', _('Full cone NAT'),\n\t\t\t_('Full cone NAT (NAT1) can improve gaming performance effectively.'));\n\t\to.value('0', _('Disable'))\n\t\to.value('2', _('Boardcom_FULLCONE_NAT'));\n\t\to.default = '0';\n\t\to.rmempty = false;\n", '\t\t/* Full cone NAT is owned by firewall (option fullcone), not TurboACC. */\n'),
    ],
    'INIT': [
        ('\tlocal fullcone\n\tconfig_get "fullcone" "config" "fullcone" "2"\n\techo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode\n', '\t# Full cone NAT is owned by firewall4 (/etc/config/firewall: option fullcone).\n\t# Do NOT touch nf_conntrack_nat_mode here (Broadcom/BCM-NAT removed) and\n\t# do NOT reload the firewall below: rebuilding the ruleset invalidates\n\t# bound HNAT/PPE entries and causes throughput fluctuation.\n\t# (kept the same line count as upstream to stay patch-friendly)\n'),
        ('\t# Cleanup firewall rules\n\tuci -q commit "firewall"\n\t/etc/init.d/firewall restart >"/dev/null" 2>&1\n', '\t# The firewall ruleset is managed by firewall4 itself; TurboACC must not\n\t# commit or reload it here. (line count preserved)\n'),
    ],
    'UCD': [
        ('\tuci -q set "turboacc.config.fastpath_mh_eth_hnat_ppenum"="2"\n', ''),
        ('uci -q set "turboacc.config.fullcone"="2"\n', '# Full cone NAT is configured in /etc/config/firewall (option fullcone 1).\n# TurboACC no longer owns any fullcone setting.\n'),
    ],
    'MK': [
        ('\t+kmod-ipt-fullconenat +kmod-fs-btrfs +kmod-bonding \\\n', '\t+kmod-nft-fullcone +kmod-fs-btrfs +kmod-bonding \\\n'),
    ],
    'RPCD': [
        ('\t\t\tif fs.access("/sys/module/xt_FULLCONENAT/refcnt") and\n\t\t\t(readfile("/sys/module/xt_FULLCONENAT/refcnt") or "0") ~= "0" then\n\t\t\t\tfctype = "xt_FULLCONENAT"\n\t\t\telseif  fs.access("/proc/sys/net/netfilter/nf_conntrack_nat_mode") and\n\t\t\t\t(readfile("/proc/sys/net/netfilter/nf_conntrack_nat_mode") or "0") ~= "0" then\n\t\t\t\tfctype = "Boardcom Fullcone"\n', '\t\t\tif fs.access("/sys/module/nft_fullcone/refcnt") and\n\t\t\t(readfile("/sys/module/nft_fullcone/refcnt") or "0") ~= "0" then\n\t\t\t\tfctype = "nft_fullcone"\n'),
    ],
    'FWP': [
        ('+\toption fullcone\t\t0\n', '+\toption fullcone\t\t1\n'),
        ('+\tlet ok = system(cmd) == 0;\n', '+\tsystem("/sbin/modprobe nft_fullcone 2>/dev/null"); let ok = system(cmd) == 0;\n'),
    ],
}


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
        print('[diy] × 找不到文件 %s' % p)
        sys.exit(1)
    s = read(p)
    hit = 0
    for old, new in pairs:
        if old in s:
            s = s.replace(old, new, 1)
            hit += 1
    write(p, s)
    print('[diy]   %s: 精确变换 %d/%d 处' % (k, hit, len(pairs)))

# ---------- 第二层：行级兜底（应对上游轻微改动）----------
s = read(FILES['JS'])
orig = s

def remove_tr(text, marker):
    """按行删除包含 marker 的整个 E('tr', {}, [...]) 元素。
    marker 必须落在同一个 tr 元素的起止行之间，否则只删 marker 所在行，
    避免孤立残留误伤前一个正常行（例如 PPE Bind Entrys 进度条）。
    """
    lines = text.splitlines(keepends=True)
    guard = 0
    while guard < 20:
        guard += 1
        idx = next((i for i, l in enumerate(lines) if marker in l), None)
        if idx is None:
            break
        st = None
        for j in range(idx, -1, -1):
            if "E('tr', {}, [" in lines[j]:
                st = j
                break
            if 'var acc_rows' in lines[j]:
                break
        if st is None:
            del lines[idx]
            continue
        en = None
        for j in range(st, min(len(lines), st + 30)):
            if re.match(r'^\s*\]\)\s*,?\s*$', lines[j].rstrip('\n')):
                en = j
                break
        if en is None or en < idx:
            del lines[idx]
            continue
        del lines[st:en + 1]
    return ''.join(lines)

def remove_func(text, name):
    """删除整个 function name(...) {...}（花括号计数）。"""
    sig = 'function %s(' % name
    while sig in text:
        st = text.find(sig)
        b = text.find('{', st)
        if b < 0:
            break
        depth = 0
        k = b
        while k < len(text):
            if text[k] == '{':
                depth += 1
            elif text[k] == '}':
                depth -= 1
                if depth == 0:
                    break
            k += 1
        end = k + 1
        while end < len(text) and text[end] in '\r\n':
            end += 1
        ls = text.rfind('\n', 0, st)
        start = ls + 1
        text = text[:start] + text[end:]
    return text

# 状态表两行（活动连接 / CPU Usage）
s = remove_tr(s, "_('Conntrack')")
s = remove_tr(s, "_('CPU Usage')")
# 辅助函数
for fn in ('formatCPUUsage', 'ct_bar_html', 'cpu_html'):
    s = remove_func(s, fn)
# poll 里两个刷新块
s = re.sub(r"[ \t]*var (?:conntrack_bar|cpu_bar) = document\.getElementById[\s\S]*?\.innerHTML;\n", '', s)
# poll 注释
s = s.replace('status + ppe/cpu/conntrack', 'status + ppe')
s = s.replace('status + ppe/conntrack', 'status + ppe')
# 两个下拉
s = re.sub(r"[ \t]*o = s\.option\(form\.ListValue, 'fastpath_mh_eth_hnat_ppenum'[\s\S]*?o\.depends\('fastpath_mh_eth_hnat', '1'\);\n", '', s)
s = re.sub(r"[ \t]*o = s\.option\(form\.ListValue, 'fullcone'[\s\S]*?o\.rmempty = false;\n",
           "\t\t/* Full cone NAT is owned by firewall (option fullcone), not TurboACC. */\n", s)
# 数组末尾元素后若留下逗号，JS 尾随逗号合法，不改也能跑；顺手清理成规范写法
s = s.replace("\t\t\t\t])\n\t\t\t];", "\t\t\t\t])\n\t\t\t];")
if s != orig:
    write(FILES['JS'], s)
    print('[diy]   JS: 行级兜底已执行（有残留块被清除）')
else:
    print('[diy]   JS: 行级兜底无需改动（第一层已全部命中）')

# ---------- 第三层：强制自检（任一失败 -> 编译终止）----------
js   = read(FILES['JS'])
ini  = read(FILES['INIT'])
ucd  = read(FILES['UCD'])
mk   = read(FILES['MK'])
rp   = read(FILES['RPCD'])
fwp  = read(FILES['FWP'])

checks = [
 ('TurboACC 下拉已移除',            "form.ListValue, 'fullcone'" not in js),
 ('CPU 占用显示已移除',             'CPU Usage' not in js and 'formatCPUUsage' not in js and 'cpu_usage_state' not in js and 'cpu_html' not in js),
 ('活动连接(Conntrack)显示已移除',   "_('Conntrack')" not in js and 'conntrack_state' not in js and 'ct_bar_html' not in js and 'Conntrack_Count' not in js),
 ('ppenum 下拉已移除',              'fastpath_mh_eth_hnat_ppenum' not in js and 'Number of HNAT PPE' not in js),
 ('ppenum 幽灵键已清理',            'fastpath_mh_eth_hnat_ppenum' not in ucd),
 ('PPE Bind Entrys 进度条保留',     'ppe_bar_html' in js and 'Bind Entrys' in js),
 ('bind_rate 下拉保留',             'fastpath_mh_eth_hnat_bind_rate' in js),
 ('init.d 不写 nat_mode',           'echo "$fullcone" > /proc/sys/net/netfilter/nf_conntrack_nat_mode' not in ini),
 ('init.d 不重载 firewall',         '/etc/init.d/firewall restart' not in ini),
 ('init.d bind_rate 仍为 30',       '"30"' in ini),
 ('uci-defaults 不再写 fullcone',   'turboacc.config.fullcone' not in ucd),
 ('依赖换成 kmod-nft-fullcone',     'kmod-nft-fullcone' in mk and 'kmod-ipt-fullconenat' not in mk),
 ('rpcd 只判 nft_fullcone',         'nft_fullcone' in rp and 'Boardcom Fullcone' not in rp),
 ('fw4 补丁默认 fullcone=1',        '+\toption fullcone\t\t1' in fwp),
 ('fw4 自检前 modprobe 保险在位',   'modprobe nft_fullcone' in fwp),
 ('fw4 补丁 hunk 计数未破坏',       '@@ -489,6 +491,25 @@' in fwp),
]

bad = 0
print('[diy] ===== 强制自检 =====')
for name, ok in checks:
    print('[diy] %s %s' % ('✓' if ok else '×', name))
    if not ok:
        bad += 1
if bad:
    print('[diy] ×× %d 项未达标，终止编译（避免产出半成品固件）' % bad)
    sys.exit(1)
print('[diy] ✓ 全部 %d 项通过' % len(checks))
PYEOF

python3 /tmp/diy_transform.py || exit 1
echo
echo "[diy] 提醒：刷完后若页面仍见『活动连接』，先强刷浏览器(Ctrl+F5)；"
echo "      再 grep -n 'Conntrack' /www/luci-static/resources/view/turboacc.js"
echo "[diy] 提醒：刷机时请勿勾选『保留配置』。旧 /etc/config/firewall 里的"
echo "      option fullcone=0 会覆盖新固件默认值；若已保留，刷完执行："
echo "      uci set firewall.@defaults[0].fullcone=1; uci commit firewall; /etc/init.d/firewall restart"

exit 0
