#!/usr/bin/env bash
# ==============================================================================
# Hysteria 2 / QUIC 高性能网络吞吐与起步加速调优脚本 (hy2-net-turbo)
# ==============================================================================

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SYSCTL_CONF="/etc/sysctl.d/99-hy2-net-turbo.conf"
SYSTEMD_SERVICE="/etc/systemd/system/initcwnd-tuning.service"

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 root 权限执行，请使用 sudo 或切换至 root 用户。"
        exit 1
    fi
}

# 1. 调整 Linux 内核长肥管道 (BDP) 网络缓冲与队列调度 (32MB 规格)
tune_kernel() {
    log_info "正在配置 Linux 内核网络栈与套接字缓冲区 (32MB 规格)..."

    # 备份原有 sysctl 配置
    if [[ -f /etc/sysctl.conf && ! -f /etc/sysctl.conf.bak.turbo ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.turbo
    fi
    mkdir -p /etc/sysctl.d

    cat << 'EOF' > "$SYSCTL_CONF"
# ====== hy2-net-turbo 自动调优配置 (32MB 旗舰规格) ======
# 套接字最大收发缓冲区扩展 (32MB)，彻底消除高并发长肥管道溢出丢包
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# 默认套接字缓冲区 (2MB)
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152

# UDP 最小缓冲区保障
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768

# 网卡接收队列深度，强化瞬时突发吸附能力
net.core.netdev_max_backlog = 16384

# 启用公平队列调度器 (Fair Queueing)
net.core.default_qdisc = fq

# 启用 BBR 拥塞控制
net.ipv4.tcp_congestion_control = bbr

# TCP 快速打开与闲置不减速
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    # 载入 BBR 模块并设置自启
    modprobe tcp_bbr 2>/dev/null || true
    if [[ -f /etc/modules ]] && ! grep -q "^tcp_bbr" /etc/modules; then
        echo "tcp_bbr" >> /etc/modules
    fi

    # 应用 sysctl
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1
    log_success "内核参数与 BBR/FQ 调度器已成功加载并生效。"
}

# 2. 调整初始拥塞窗口 (InitCWND) 消除起步爬坡延迟并持久化
tune_initcwnd() {
    local target_cwnd=50
    local target_rwnd=50
    log_info "正在配置默认路由初始拥塞窗口 (initcwnd=${target_cwnd}, initrwnd=${target_rwnd})..."

    # 提取默认路由网关和网卡
    local gw dev
    gw=$(ip route show default | awk '{print $3}' | head -n1)
    dev=$(ip route show default | awk '{print $5}' | head -n1)

    if [[ -n "$gw" && -n "$dev" ]]; then
        ip route change default via "$gw" dev "$dev" initcwnd "$target_cwnd" initrwnd "$target_rwnd" 2>/dev/null || true
        log_success "默认路由已热更新为弹射起步模式 (initcwnd=${target_cwnd})。"
    else
        log_warn "未检测到默认路由网关，跳过实时路由热应用。"
    fi

    # 创建 systemd 开机自启服务保证持久化
    cat << EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=Set Route initcwnd and initrwnd (hy2-net-turbo)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'GW=\$(ip route show default | awk "{print \\\$3}"); DEV=\$(ip route show default | awk "{print \\\$5}"); if [ -n "\$GW" ] && [ -n "\$DEV" ]; then ip route change default via "\$GW" dev "\$DEV" initcwnd ${target_cwnd} initrwnd ${target_rwnd}; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable initcwnd-tuning.service >/dev/null 2>&1
    log_success "已建立 systemd 守护服务，网络重置或开机重启将自动保持调优状态。"
}

# 3. 部署端口跳跃 (Port Hopping NAT REDIRECT)
setup_port_hopping() {
    local port_range="$1"
    local target_port="$2"

    if [[ -z "$port_range" || -z "$target_port" ]]; then
        log_error "参数错误！用法: $0 --port-hopping <起始端口:结束端口> <服务内部监听端口>"
        exit 1
    fi

    log_info "正在配置端口跳跃 NAT 重定向: UDP ${port_range} -> ${target_port}..."

    # 如果系统开启了 UFW
    if command -v ufw >/dev/null && ufw status | grep -qw "active"; then
        if [[ -f /etc/ufw/before.rules ]] && ! grep -q "hy2-net-turbo port hopping" /etc/ufw/before.rules; then
            cp /etc/ufw/before.rules /etc/ufw/before.rules.bak.turbo
            cat << EOF > /tmp/ufw_nat.tmp
# ====== hy2-net-turbo port hopping NAT 规则 ======
*nat
:PREROUTING ACCEPT [0:0]
-A PREROUTING -p udp --dport ${port_range} -j REDIRECT --to-ports ${target_port}
COMMIT
# =================================================

EOF
            cat /tmp/ufw_nat.tmp /etc/ufw/before.rules > /tmp/before.rules.new
            mv /tmp/before.rules.new /etc/ufw/before.rules
            rm -f /tmp/ufw_nat.tmp
        fi
        ufw allow "${port_range}/udp" comment "hy2-net-turbo port hopping" >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1
    else
        # 纯 iptables 模式
        iptables -t nat -A PREROUTING -p udp --dport "$port_range" -j REDIRECT --to-ports "$target_port"
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi

    log_success "端口跳跃规则部署完成！UDP 端口段 ${port_range} 已全量重定向至 ${target_port}。"
}

# 查看当前调优状态
show_status() {
    echo -e "\n${BLUE}===================== 当前网络性能参数诊断 =====================${NC}"
    echo -n "• 套接字接收缓冲 (rmem_max): "
    sysctl -n net.core.rmem_max 2>/dev/null || echo "未设置"
    echo -n "• 套接字发送缓冲 (wmem_max): "
    sysctl -n net.core.wmem_max 2>/dev/null || echo "未设置"
    echo -n "• 默认队列调度器 (qdisc):   "
    sysctl -n net.core.default_qdisc 2>/dev/null || echo "未设置"
    echo -n "• 拥塞控制算法 (cc):         "
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未设置"
    echo -n "• 网卡接收队列 (backlog):   "
    sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "未设置"
    echo -n "• 默认路由参数:             "
    ip route show default 2>/dev/null || echo "未找到默认路由"
    echo -n "• 系统 UDP 缓冲区丢包统计:  "
    awk '/Udp:.*InErrors/ {getline; print "InErrors="$3, "RcvbufErrors="$5, "SndbufErrors="$6}' /proc/net/snmp 2>/dev/null || echo "无法获取"
    echo -e "${BLUE}================================================================${NC}\n"
}

# 卸载与恢复
uninstall() {
    log_info "正在还原系统网络配置..."
    rm -f "$SYSCTL_CONF"
    if [[ -f /etc/sysctl.conf.bak.turbo ]]; then
        mv /etc/sysctl.conf.bak.turbo /etc/sysctl.conf
    fi
    sysctl --system >/dev/null 2>&1 || true

    if [[ -f "$SYSTEMD_SERVICE" ]]; then
        systemctl disable --now initcwnd-tuning.service >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_SERVICE"
        systemctl daemon-reload
    fi

    # 还原默认路由
    local gw dev
    gw=$(ip route show default | awk '{print $3}' | head -n1)
    dev=$(ip route show default | awk '{print $5}' | head -n1)
    if [[ -n "$gw" && -n "$dev" ]]; then
        ip route change default via "$gw" dev "$dev" 2>/dev/null || true
    fi

    log_success "所有调优参数与守护服务已彻底移除并恢复默认。"
}

main() {
    check_root

    case "$1" in
        --port-hopping)
            setup_port_hopping "$2" "$3"
            ;;
        --status)
            show_status
            ;;
        --uninstall)
            uninstall
            ;;
        *)
            echo -e "${CYAN}====================================================${NC}"
            echo -e "${GREEN}      Hysteria 2 / QUIC 高性能网络加速优化器        ${NC}"
            echo -e "${CYAN}====================================================${NC}"
            tune_kernel
            tune_initcwnd
            show_status
            log_success "全部优化已成功执行！现有网络连接完全无感保持，吞吐与起步加速已就绪。"
            ;;
    esac
}

main "$@"
