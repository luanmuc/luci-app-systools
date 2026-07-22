#!/bin/sh
# LAN IP 地址修改后端脚本
# 修改路由器LAN口IP地址和子网掩码
# 完善的校验、回滚、并发安全机制

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

# ========== 工具函数 ==========

# IP地址转整数
ip_to_int() {
    local ip="$1"
    local a b c d
    a=$(echo "$ip" | cut -d. -f1)
    b=$(echo "$ip" | cut -d. -f2)
    c=$(echo "$ip" | cut -d. -f3)
    d=$(echo "$ip" | cut -d. -f4)
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# 整数转IP地址
int_to_ip() {
    local num="$1"
    local a=$(( (num >> 24) & 0xFF ))
    local b=$(( (num >> 16) & 0xFF ))
    local c=$(( (num >> 8) & 0xFF ))
    local d=$(( num & 0xFF ))
    echo "${a}.${b}.${c}.${d}"
}

# 计算网络地址
calc_network() {
    local ip="$1"
    local mask="$2"
    local ip_int mask_int net_int
    ip_int=$(ip_to_int "$ip")
    mask_int=$(ip_to_int "$mask")
    net_int=$(( ip_int & mask_int ))
    int_to_ip "$net_int"
}

# 计算广播地址
calc_broadcast() {
    local ip="$1"
    local mask="$2"
    local ip_int mask_int bc_int
    ip_int=$(ip_to_int "$ip")
    mask_int=$(ip_to_int "$mask")
    bc_int=$(( ip_int | (~mask_int & 0xFFFFFFFF) ))
    int_to_ip "$bc_int"
}

# ========== 配置读取 ==========

# 获取当前LAN配置
get_lan_config() {
    local ipaddr netmask
    ipaddr=$(uci -q get network.lan.ipaddr)
    netmask=$(uci -q get network.lan.netmask)
    echo "ipaddr=${ipaddr:-N/A}"
    echo "netmask=${netmask:-N/A}"
}

# 获取DHCP配置
get_dhcp_config() {
    local dhcp_start dhcp_limit
    dhcp_start=$(uci -q get dhcp.lan.start)
    dhcp_limit=$(uci -q get dhcp.lan.limit)
    echo "dhcp_start=${dhcp_start:-}"
    echo "dhcp_limit=${dhcp_limit:-}"
}

# ========== 校验函数 ==========

# 验证IP地址合法性（除了格式，还要检查特殊地址）
validate_lan_ip() {
    local ip="$1"
    
    # 基础格式校验
    if ! is_valid_ip "$ip"; then
        log_error "IP地址格式无效: $ip"
        return 1
    fi
    
    # 不能是 0.0.0.0
    if [ "$ip" = "0.0.0.0" ]; then
        log_error "不能使用 0.0.0.0 作为LAN IP"
        return 1
    fi
    
    # 不能是 255.255.255.255（全局广播地址）
    if [ "$ip" = "255.255.255.255" ]; then
        log_error "不能使用广播地址作为LAN IP"
        return 1
    fi
    
    # 不能是 127.x.x.x（回环地址）
    if echo "$ip" | grep -q '^127\.'; then
        log_error "不能使用回环地址作为LAN IP"
        return 1
    fi
    
    # 不能是组播地址（224.0.0.0 - 239.255.255.255）
    local first_octet
    first_octet=$(echo "$ip" | cut -d. -f1)
    if [ "$first_octet" -ge 224 ] && [ "$first_octet" -le 239 ]; then
        log_error "不能使用组播地址作为LAN IP"
        return 1
    fi
    
    return 0
}

# 验证子网掩码合法性
validate_netmask() {
    local mask="$1"
    
    if ! is_valid_ip "$mask"; then
        log_error "子网掩码格式无效: $mask"
        return 1
    fi
    
    # 所有合法的连续子网掩码
    case "$mask" in
        255.0.0.0|255.128.0.0|255.192.0.0|255.224.0.0|255.240.0.0|\
        255.248.0.0|255.252.0.0|255.254.0.0|255.255.0.0|\
        255.255.128.0|255.255.192.0|255.255.224.0|255.255.240.0|\
        255.255.248.0|255.255.252.0|255.255.254.0|255.255.255.0|\
        255.255.255.128|255.255.255.192|255.255.255.224|\
        255.255.255.240|255.255.255.248|255.255.255.252|\
        255.255.255.254)
            return 0
            ;;
        *)
            log_error "无效的子网掩码: $mask"
            return 1
            ;;
    esac
}

# 检查IP是否是给定子网的网络地址或广播地址
is_network_or_broadcast() {
    local ip="$1"
    local mask="$2"
    local network broadcast
    
    network=$(calc_network "$ip" "$mask")
    broadcast=$(calc_broadcast "$ip" "$mask")
    
    if [ "$ip" = "$network" ]; then
        log_error "IP地址 $ip 是网络地址，不能作为LAN IP"
        return 0
    fi
    
    if [ "$ip" = "$broadcast" ]; then
        log_error "IP地址 $ip 是广播地址，不能作为LAN IP"
        return 0
    fi
    
    return 1
}

# ========== DHCP 同步 ==========

# 检查并调整DHCP地址池，使其与新LAN IP在同一网段
adjust_dhcp_pool() {
    local new_ip="$1"
    local new_mask="$2"
    local new_network dhcp_start dhcp_limit dhcp_start_ip old_network
    
    new_network=$(calc_network "$new_ip" "$new_mask")
    dhcp_start=$(uci -q get dhcp.lan.start)
    dhcp_limit=$(uci -q get dhcp.lan.limit)
    
    # 如果没有DHCP配置，跳过
    if [ -z "$dhcp_start" ] || [ -z "$dhcp_limit" ]; then
        log_info "未检测到DHCP配置，跳过DHCP调整"
        return 0
    fi
    
    # 获取当前DHCP起始IP（基于旧网段）
    local old_ip old_mask
    old_ip=$(uci -q get network.lan.ipaddr)
    old_mask=$(uci -q get network.lan.netmask)
    old_network=$(calc_network "$old_ip" "$old_mask")
    
    # 如果新旧网段相同，不需要调整
    if [ "$new_network" = "$old_network" ]; then
        return 0
    fi
    
    # 计算新网段的DHCP起始IP（保持相同的主机偏移，默认从100开始）
    # 策略：新网段网络地址 + 100 作为起始
    local net_int start_int new_start_ip
    net_int=$(ip_to_int "$new_network")
    start_int=$(( net_int + 100 ))
    new_start_ip=$(int_to_ip "$start_int")
    
    # 只取最后一段作为start值（OpenWrt的dhcp.start是相对网络地址的偏移）
    local new_start_offset
    new_start_offset=$(echo "$new_start_ip" | cut -d. -f4)
    
    log_info "DHCP网段变化，自动调整地址池: 起始偏移改为 $new_start_offset"
    uci set dhcp.lan.start="$new_start_offset"
    uci commit dhcp
    
    return 0
}

# ========== 主功能函数 ==========

# 应用新的LAN IP配置
apply_lan_ip() {
    local new_ip="$1"
    local new_mask="${2:-255.255.255.0}"
    local current_ip current_mask backup_file
    
    log_info "开始修改LAN IP: $new_ip / $new_mask"
    
    # 获取当前配置
    current_ip=$(uci -q get network.lan.ipaddr)
    current_mask=$(uci -q get network.lan.netmask)
    
    # 检查是否与当前配置完全相同
    if [ "$new_ip" = "$current_ip" ] && [ "$new_mask" = "$current_mask" ]; then
        log_info "新配置与当前配置相同，无需修改"
        echo "SAME"
        return 0
    fi
    
    # 获取操作锁，防止并发修改
    if ! acquire_lock "lan_ip"; then
        log_error "另一个网络配置操作正在进行中，请稍后再试"
        echo "LOCKED"
        return 1
    fi
    
    # 设置trap确保锁被释放（异常退出时）
    trap 'release_lock "lan_ip"' EXIT
    
    # 校验参数
    if ! validate_lan_ip "$new_ip"; then
        echo "INVALID_IP"
        return 1
    fi
    
    if ! validate_netmask "$new_mask"; then
        echo "INVALID_MASK"
        return 1
    fi
    
    # 检查是否是网络地址或广播地址
    if is_network_or_broadcast "$new_ip" "$new_mask"; then
        echo "INVALID_SPECIAL"
        return 1
    fi
    
    # 备份当前network配置（带时间戳，不覆盖）
    local backup_suffix=".bak.lanip.$(date +%Y%m%d_%H%M%S)"
    backup_file /etc/config/network "$backup_suffix"
    backup_file /etc/config/dhcp "$backup_suffix"
    
    # 修改 UCI 配置
    if ! uci set network.lan.ipaddr="$new_ip"; then
        log_error "设置LAN IP失败"
        echo "UCI_ERROR"
        return 1
    fi
    
    if ! uci set network.lan.netmask="$new_mask"; then
        log_error "设置子网掩码失败，回滚配置"
        uci revert network
        echo "UCI_ERROR"
        return 1
    fi
    
    # 调整DHCP地址池（如果需要）
    adjust_dhcp_pool "$new_ip" "$new_mask"
    
    # 提交配置
    if ! uci commit network; then
        log_error "提交network配置失败，回滚"
        uci revert network
        uci revert dhcp
        echo "COMMIT_ERROR"
        return 1
    fi
    
    if ! uci commit dhcp; then
        log_error "提交dhcp配置失败"
        uci revert dhcp
        # network已经提交了，这里只能记录错误
    fi
    
    log_info "LAN IP配置已更新，正在重启网络..."
    
    # 后台重启网络（延迟执行，让当前请求先返回）
    # 子进程独立释放锁
    (
        trap 'release_lock "lan_ip"' EXIT
        sleep 2
        
        # 直接restart，不用reload（reload可能部分生效导致异常）
        if /etc/init.d/network restart 2>/dev/null; then
            log_info "网络服务已重启，新LAN IP生效: $new_ip"
        else
            log_error "网络服务重启失败，请手动检查"
        fi
    ) &
    
    # 主进程不释放锁，交给后台子进程释放（通过trap保证）
    # 先移除主进程的trap，避免主进程退出时释放锁
    trap - EXIT
    
    echo "SUCCESS"
    return 0
}

# ========== 主入口 ==========

case "$1" in
    status)
        get_lan_config
        ;;
    apply)
        if [ -z "$2" ]; then
            echo "用法: $0 apply <ip_address> [netmask]"
            exit 1
        fi
        apply_lan_ip "$2" "${3:-255.255.255.0}"
        ;;
    *)
        echo "用法: $0 {status|apply}"
        echo "  status  - 显示当前LAN IP配置"
        echo "  apply   - 应用新的LAN IP配置"
        exit 1
        ;;
esac

exit 0
