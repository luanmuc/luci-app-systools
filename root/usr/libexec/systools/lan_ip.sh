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
    
    # 防御性检查，确保都是数字
    case "$a$b$c$d" in
        *[!0-9]*) return 1 ;;
    esac
    
    echo "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
    return 0
}

# 整数转IP地址
int_to_ip() {
    local num="$1"
    local a b c d
    a=$(( (num >> 24) & 0xFF ))
    b=$(( (num >> 16) & 0xFF ))
    c=$(( (num >> 8) & 0xFF ))
    d=$(( num & 0xFF ))
    echo "${a}.${b}.${c}.${d}"
}

# 计算网络地址
calc_network() {
    local ip="$1"
    local mask="$2"
    local ip_int mask_int net_int
    ip_int=$(ip_to_int "$ip") || return 1
    mask_int=$(ip_to_int "$mask") || return 1
    net_int=$(( ip_int & mask_int ))
    int_to_ip "$net_int"
}

# 计算广播地址（避免使用 ~ 按位取反，提高兼容性）
calc_broadcast() {
    local ip="$1"
    local mask="$2"
    local ip_int mask_int inverted_mask bc_int
    ip_int=$(ip_to_int "$ip") || return 1
    mask_int=$(ip_to_int "$mask") || return 1
    # 用 0xFFFFFFFF XOR mask 实现按位取反，避免 ~ 运算符兼容性问题
    inverted_mask=$(( 0xFFFFFFFF ^ mask_int ))
    bc_int=$(( ip_int | inverted_mask ))
    int_to_ip "$bc_int"
}

# 清理过期备份文件，只保留最近N份
cleanup_old_backups() {
    local file_pattern="$1"
    local keep_count="${2:-5}"
    local count=0
    
    # 按修改时间倒序列出，跳过前N个，删除剩下的
    ls -1t "$file_pattern" 2>/dev/null | while read -r f; do
        count=$((count + 1))
        if [ "$count" -gt "$keep_count" ]; then
            rm -f "$f" 2>/dev/null
        fi
    done
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
    # 防御性检查：确保是数字
    case "$first_octet" in
        *[!0-9]*) return 1 ;;
    esac
    if [ "$first_octet" -ge 224 ] 2>/dev/null && [ "$first_octet" -le 239 ] 2>/dev/null; then
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
    
    # 所有合法的连续子网掩码（共31个，/1 到 /31）
    case "$mask" in
        128.0.0.0|\
        192.0.0.0|224.0.0.0|240.0.0.0|248.0.0.0|252.0.0.0|254.0.0.0|255.0.0.0|\
        255.128.0.0|255.192.0.0|255.224.0.0|255.240.0.0|\
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
# 返回0=是特殊地址（无效），返回1=不是特殊地址（有效）
is_network_or_broadcast() {
    local ip="$1"
    local mask="$2"
    local network broadcast
    
    network=$(calc_network "$ip" "$mask") || return 0
    broadcast=$(calc_broadcast "$ip" "$mask") || return 0
    
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

# ========== 主功能函数 ==========

# 应用新的LAN IP配置
apply_lan_ip() {
    local new_ip="$1"
    local new_mask="${2:-255.255.255.0}"
    local current_ip current_mask
    
    log_info "开始修改LAN IP: $new_ip / $new_mask"
    
    # 获取当前配置（在任何修改之前读取，确保是原始值）
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
    
    # 清理旧备份，只保留最近5份
    cleanup_old_backups "/etc/config/network.bak.lanip.*" 5
    
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
    
    # 提交配置
    if ! uci commit network; then
        log_error "提交network配置失败，回滚"
        uci revert network
        echo "COMMIT_ERROR"
        return 1
    fi
    
    log_info "LAN IP配置已更新，正在重启网络..."
    
    # 后台重启网络（延迟执行，让当前请求先返回）
    # 子进程独立持有锁
    (
        # 更新锁的PID为当前子进程PID，防止父进程退出后被误判为过期锁
        echo $$ > "/var/run/systools_lan_ip.lock/pid" 2>/dev/null
        
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
