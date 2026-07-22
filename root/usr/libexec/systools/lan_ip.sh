#!/bin/sh
# LAN IP 地址修改后端脚本
# 修改路由器LAN口IP地址和子网掩码

# 加载公共函数库
. /usr/libexec/systools/systools-common.sh

# 获取当前LAN配置
get_lan_config() {
    local ipaddr netmask
    ipaddr=$(uci -q get network.lan.ipaddr)
    netmask=$(uci -q get network.lan.netmask)
    echo "ipaddr=${ipaddr:-N/A}"
    echo "netmask=${netmask:-N/A}"
}

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
    
    # 不能是 255.255.255.255（广播地址）
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
    
    # 简单检查：常见的合法子网掩码
    case "$mask" in
        255.0.0.0|255.128.0.0|255.192.0.0|255.224.0.0|255.240.0.0|\
        255.248.0.0|255.252.0.0|255.254.0.0|255.255.0.0|\
        255.255.128.0|255.255.192.0|255.255.224.0|255.255.240.0|\
        255.255.248.0|255.255.252.0|255.255.254.0|255.255.255.0|\
        255.255.255.128|255.255.255.192|255.255.255.224|\
        255.255.255.240|255.255.255.248|255.255.255.252)
            return 0
            ;;
        *)
            log_error "无效的子网掩码: $mask"
            return 1
            ;;
    esac
}

# 应用新的LAN IP配置
apply_lan_ip() {
    local new_ip="$1"
    local new_mask="${2:-255.255.255.0}"
    
    log_info "开始修改LAN IP: $new_ip / $new_mask"
    
    # 获取操作锁，防止并发修改
    if ! acquire_lock "lan_ip"; then
        log_error "另一个网络配置操作正在进行中，请稍后再试"
        return 1
    fi
    
    # 校验参数
    if ! validate_lan_ip "$new_ip"; then
        release_lock "lan_ip"
        return 1
    fi
    
    if ! validate_netmask "$new_mask"; then
        release_lock "lan_ip"
        return 1
    fi
    
    # 备份当前network配置
    backup_file /etc/config/network ".bak.lanip"
    
    # 修改 UCI 配置
    uci set network.lan.ipaddr="$new_ip"
    uci set network.lan.netmask="$new_mask"
    uci commit network
    
    log_info "LAN IP配置已更新，正在重启网络..."
    
    # 重启网络服务（后台执行，避免脚本被中断）
    (
        sleep 2
        /etc/init.d/network reload 2>/dev/null || /etc/init.d/network restart 2>/dev/null
        log_info "网络服务已重启，新LAN IP生效: $new_ip"
        release_lock "lan_ip"
    ) &
    
    return 0
}

# 主入口
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
