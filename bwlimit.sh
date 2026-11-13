#!/usr/bin/env bash
# bwlimit.sh — 用 tc 把 Linux VPS 的带宽限制为固定值
#
# 用法:
#   bwlimit.sh start   -d 5 [-u 5] [-i eth0]   立即生效 (单位 Mbps, 也可写 500kbit / 5mbit)
#   bwlimit.sh stop    [-i eth0]               取消限速
#   bwlimit.sh status  [-i eth0]               查看当前规则和统计
#   bwlimit.sh install -d 5 [-u 5] [-i eth0]   安装为 systemd 服务, 开机自动限速
#   bwlimit.sh uninstall                       取消限速并移除服务
#
#   -d  入口(下载/ingress)限速      -u  出口(上传/egress)限速      -i  网卡, 默认自动检测
#   -d 和 -u 至少给一个; 只给 -d 就只限入口。
#
# 例: 入口限制为 5Mbps      bwlimit.sh start -d 5
#     入口出口都限 5Mbps    bwlimit.sh start -d 5 -u 5

set -euo pipefail

IFB="ifb-bwl"                         # 入口限速用的虚拟网卡
INSTALL_PATH="/usr/local/sbin/bwlimit"
UNIT="/etc/systemd/system/bwlimit.service"

die() { echo "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法:
  bwlimit start   -d 5 [-u 5] [-i eth0]   立即生效 (单位 Mbps, 也可写 500kbit / 5mbit)
  bwlimit stop    [-i eth0]               取消限速
  bwlimit status  [-i eth0]               查看当前规则和统计
  bwlimit install -d 5 [-u 5] [-i eth0]   安装为 systemd 服务, 开机自动限速
  bwlimit uninstall                       取消限速并移除服务

  -d 入口(下载)限速   -u 出口(上传)限速   -i 网卡, 默认自动检测
EOF
    exit "${1:-0}"
}

# 纯数字按 Mbps 处理, 否则原样交给 tc (kbit/mbit/gbit)
norm_rate() {
    local r
    r=$(echo "$1" | tr 'A-Z' 'a-z')
    case "$r" in
        *[!0-9.]*) r=${r%ps}; echo "$r" ;;   # 5mbps -> 5mbit 需要再处理
        *)         echo "${r}mbit" ;;
    esac
}
fix_unit() { echo "$1" | sed -e 's/mb$/mbit/' -e 's/kb$/kbit/' -e 's/gb$/gbit/' -e 's/m$/mbit/' -e 's/k$/kbit/' -e 's/g$/gbit/'; }

detect_iface() {
    local i
    i=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$i" ] || i=$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$i" ] || die "检测不到默认网卡, 请用 -i 指定"
    echo "$i"
}

clear_rules() {
    local dev=$1
    tc qdisc del dev "$dev" root    2>/dev/null || true
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
    ip link del "$IFB"              2>/dev/null || true
}

# 在指定设备的出方向挂一个固定速率的 HTB + fq_codel
shape() {
    local dev=$1 rate=$2
    tc qdisc replace dev "$dev" root handle 1: htb default 10
    tc class replace dev "$dev" parent 1: classid 1:10 htb rate "$rate" ceil "$rate"
    tc qdisc replace dev "$dev" parent 1:10 handle 10: fq_codel 2>/dev/null \
        || tc qdisc replace dev "$dev" parent 1:10 handle 10: sfq perturb 10
}

do_start() {
    [ -n "$DOWN" ] || [ -n "$UP" ] || die "请至少指定 -d 或 -u"
    clear_rules "$DEV"

    if [ -n "$UP" ]; then
        shape "$DEV" "$UP"
        echo "出口 ($DEV): $UP"
    fi

    if [ -n "$DOWN" ]; then
        tc qdisc add dev "$DEV" handle ffff: ingress
        modprobe ifb numifbs=0 2>/dev/null || true
        if ip link add "$IFB" type ifb 2>/dev/null && ip link set "$IFB" up; then
            # 入口流量重定向到 ifb, 在 ifb 上做整形(排队, 对 TCP 更平滑)
            tc filter add dev "$DEV" parent ffff: protocol all u32 match u32 0 0 \
                action mirred egress redirect dev "$IFB"
            shape "$IFB" "$DOWN"
            echo "入口 ($DEV): $DOWN  [ifb 整形]"
        else
            # 内核没有 ifb 模块(部分 OpenVZ/LXC), 退化为直接丢包限速
            tc filter add dev "$DEV" parent ffff: protocol all u32 match u32 0 0 \
                police rate "$DOWN" burst 256k drop flowid :1
            echo "入口 ($DEV): $DOWN  [police 丢包, 无 ifb 模块]"
        fi
    fi
}

do_status() {
    echo "== $DEV qdisc =="; tc -s qdisc show dev "$DEV"
    echo "== $DEV class =="; tc -s class show dev "$DEV"
    echo "== $DEV ingress filter =="; tc filter show dev "$DEV" parent ffff: 2>/dev/null || true
    if ip link show "$IFB" >/dev/null 2>&1; then
        echo "== $IFB class =="; tc -s class show dev "$IFB"
    fi
}

do_install() {
    [ -n "$DOWN" ] || [ -n "$UP" ] || die "请至少指定 -d 或 -u"
    command -v systemctl >/dev/null || die "没有 systemd, 请自行把 start 命令加入开机脚本"
    if [ ! -f "$0" ]; then
        die "通过管道运行时无法安装自身, 请先下载到 $INSTALL_PATH 再执行 install (见 README)"
    elif [ "$(readlink -f "$0")" != "$(readlink -f "$INSTALL_PATH")" ]; then
        install -m 755 "$0" "$INSTALL_PATH"
    fi
    local args="-i $DEV"
    [ -n "$DOWN" ] && args="$args -d $DOWN"
    [ -n "$UP" ]   && args="$args -u $UP"
    cat > "$UNIT" <<EOF
[Unit]
Description=Bandwidth limit ($args)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH start $args
ExecStop=$INSTALL_PATH stop -i $DEV

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bwlimit.service
    systemctl restart bwlimit.service
    echo "已安装并启用 bwlimit.service (开机自动生效)"
}

do_uninstall() {
    if [ -f "$UNIT" ]; then
        systemctl disable --now bwlimit.service 2>/dev/null || true
        rm -f "$UNIT"
        systemctl daemon-reload
    fi
    clear_rules "$DEV"
    rm -f "$INSTALL_PATH"
    echo "已卸载"
}

# ---- 参数解析 ----
[ $# -ge 1 ] || usage 1
CMD=$1; shift
DEV=""; DOWN=""; UP=""
while getopts "i:d:u:h" opt; do
    case $opt in
        i) DEV=$OPTARG ;;
        d) DOWN=$(fix_unit "$(norm_rate "$OPTARG")") ;;
        u) UP=$(fix_unit "$(norm_rate "$OPTARG")") ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done

case $CMD in -h|--help|help) usage 0 ;; esac
[ "$(id -u)" -eq 0 ] || die "需要 root 权限 (sudo)"
command -v tc >/dev/null || die "找不到 tc, 请先安装 iproute2 (apt install iproute2 / yum install iproute-tc)"
[ -n "$DEV" ] || DEV=$(detect_iface)
ip link show "$DEV" >/dev/null 2>&1 || die "网卡 $DEV 不存在"

case $CMD in
    start)     do_start ;;
    stop)      clear_rules "$DEV"; echo "已取消 $DEV 的限速" ;;
    status)    do_status ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         usage 1 ;;
esac
