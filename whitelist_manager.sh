#!/bin/bash
################################################################################
# IP 白名单管理脚本 - 一体化版本
# 功能：
#   1. 从百度IP列表自动获取并转换为C段
#   2. 配置iptables白名单模式
#   3. 只允许指定IP访问，其他全部拒绝
#   4. 提供查看、保存、恢复、清除等管理功能
#
# 用法:
#   交互模式: sudo ./whitelist_manager.sh
#   全自动模式: sudo ./whitelist_manager.sh --auto
#              (清空规则 -> 下载IP -> 配置白名单 -> 保存，无需确认)
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

################################################################################
# 配置区域（可修改）
################################################################################

# 百度IP列表URL
BAIDU_IP_URL="http://ip.3306.site/data/baidu.txt"

# 自定义白名单IP（请根据实际情况修改）
CUSTOM_WHITELIST=(
    # "150.109.125.0/24"    # 示例：你的办公网络
    # "124.13.164.0/24"     # 示例：你的家庭网络
    # "1.2.3.4"             # 示例：单个IP
)

# 是否自动添加当前SSH连接的IP到白名单（推荐开启）
AUTO_ADD_CURRENT_IP=true

# 是否添加内网段到白名单
ADD_PRIVATE_NETWORKS=true

# 是否启用百度爬虫白名单
ENABLE_BAIDU_WHITELIST=true

################################################################################
# 全局变量
################################################################################

TEMP_FILE="/tmp/baidu_ips_$$.txt"
BACKUP_DIR="/root/iptables_backups"
CURRENT_USER_IP=""

# 百度IP段数组（将在运行时填充）
declare -A BAIDU_SEGMENTS

################################################################################
# 工具函数
################################################################################

# 打印标题
print_header() {
    echo ""
    echo "=========================================="
    echo "  $1"
    echo "=========================================="
}

# 打印成功消息
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# 打印错误消息
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# 打印警告消息
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# 打印信息消息
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# 检查是否为root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 sudo 运行此脚本"
        exit 1
    fi
}

# 检测当前用户IP
detect_current_ip() {
    local ip=""
    
    # 尝试从SSH_CONNECTION获取
    if [ -n "$SSH_CONNECTION" ]; then
        ip=$(echo $SSH_CONNECTION | awk '{print $1}')
    fi
    
    # 尝试从SSH_CLIENT获取
    if [ -z "$ip" ] && [ -n "$SSH_CLIENT" ]; then
        ip=$(echo $SSH_CLIENT | awk '{print $1}')
    fi
    
    # 尝试从who命令获取
    if [ -z "$ip" ]; then
        ip=$(who am i | awk '{print $5}' | sed 's/[()]//g')
    fi
    
    CURRENT_USER_IP="$ip"
}

# 转换IP为C段
ip_to_c_segment() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        # 如果已经是CIDR格式，检查掩码
        if [[ "$ip" =~ / ]]; then
            echo "$ip"
        else
            # 转换为C段
            local c_segment=$(echo "$ip" | cut -d. -f1-3)
            echo "${c_segment}.0/24"
        fi
    else
        echo ""
    fi
}

################################################################################
# 核心功能函数
################################################################################

# 下载并解析百度IP列表
fetch_baidu_ips() {
    print_header "获取百度IP列表"
    
    if [ "$ENABLE_BAIDU_WHITELIST" != "true" ]; then
        print_warning "百度白名单功能未启用，跳过"
        return 0
    fi
    
    echo -e "${CYAN}正在从以下URL下载IP列表：${NC}"
    echo "  $BAIDU_IP_URL"
    echo ""
    
    # 下载文件
    if ! curl -s -f -o "$TEMP_FILE" "$BAIDU_IP_URL"; then
        print_error "下载失败，请检查网络或URL"
        return 1
    fi
    
    print_success "下载成功"
    
    # 解析并转换为C段
    echo ""
    echo -e "${CYAN}正在解析IP并转换为C段...${NC}"
    
    local total_count=0
    local valid_count=0
    
    while IFS= read -r line; do
        # 跳过空行、注释和分隔符
        [[ -z "$line" || "$line" =~ ^# || "$line" =~ ^____ ]] && continue
        
        total_count=$((total_count + 1))
        
        # 清理空格
        local ip=$(echo "$line" | tr -d '[:space:]')
        
        # 验证IP格式
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # 转换为C段
            local c_segment=$(echo "$ip" | cut -d. -f1-3)
            local cidr="${c_segment}.0/24"
            
            # 使用关联数组去重
            if [[ -z "${BAIDU_SEGMENTS[$cidr]}" ]]; then
                BAIDU_SEGMENTS[$cidr]=1
                valid_count=$((valid_count + 1))
            fi
        fi
    done < "$TEMP_FILE"
    
    print_success "解析完成"
    print_info "总IP数: $total_count 个"
    print_info "去重后C段: ${#BAIDU_SEGMENTS[@]} 个"
    
    return 0
}

# 显示将要添加的白名单
show_whitelist_preview() {
    print_header "白名单预览"
    
    local total=0
    
    # 系统必需
    echo -e "${MAGENTA}[系统必需]${NC}"
    echo "  - 127.0.0.1 (本机回环)"
    echo "  - ESTABLISHED,RELATED (已建立的连接)"
    echo ""
    
    # 当前用户IP
    if [ -n "$CURRENT_USER_IP" ]; then
        echo -e "${MAGENTA}[当前SSH连接]${NC}"
        local c_seg=$(ip_to_c_segment "$CURRENT_USER_IP")
        echo "  - $CURRENT_USER_IP → $c_seg"
        total=$((total + 1))
        echo ""
    fi
    
    # 自定义白名单
    if [ ${#CUSTOM_WHITELIST[@]} -gt 0 ]; then
        echo -e "${MAGENTA}[自定义白名单]${NC}"
        for ip in "${CUSTOM_WHITELIST[@]}"; do
            echo "  - $ip"
            total=$((total + 1))
        done
        echo ""
    fi
    
    # 内网段
    if [ "$ADD_PRIVATE_NETWORKS" = "true" ]; then
        echo -e "${MAGENTA}[内网段]${NC}"
        echo "  - 192.168.0.0/16"
        echo "  - 10.0.0.0/8"
        echo "  - 172.16.0.0/12"
        total=$((total + 3))
        echo ""
    fi
    
    # 百度IP段
    if [ ${#BAIDU_SEGMENTS[@]} -gt 0 ]; then
        echo -e "${MAGENTA}[百度爬虫] ${#BAIDU_SEGMENTS[@]} 个C段${NC}"
        local count=0
        for segment in "${!BAIDU_SEGMENTS[@]}"; do
            if [ $count -lt 5 ]; then
                echo "  - $segment"
            fi
            count=$((count + 1))
        done
        if [ ${#BAIDU_SEGMENTS[@]} -gt 5 ]; then
            echo "  ... (还有 $((${#BAIDU_SEGMENTS[@]} - 5)) 个)"
        fi
        total=$((total + ${#BAIDU_SEGMENTS[@]}))
        echo ""
    fi
    
    echo -e "${CYAN}总计: $total 个IP/IP段将被允许${NC}"
    echo -e "${RED}其他所有IP将被拒绝！${NC}"
}

# 应用iptables规则
apply_iptables_rules() {
    print_header "应用iptables规则"
    
    # 备份当前规则
    echo ""
    echo -e "${CYAN}[1/6] 备份当前规则...${NC}"
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/iptables_$(date +%Y%m%d_%H%M%S).rules"
    iptables-save > "$backup_file"
    print_success "已备份到: $backup_file"
    
    # 清空INPUT链
    echo ""
    echo -e "${CYAN}[2/6] 清空INPUT规则...${NC}"
    iptables -F INPUT
    print_success "已清空INPUT链"
    
    # 1. 允许本机回环
    echo ""
    echo -e "${CYAN}[3/6] 添加系统必需规则...${NC}"
    iptables -A INPUT -i lo -j ACCEPT
    print_success "已允许本机回环"
    
    # 2. 允许已建立的连接
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    print_success "已允许已建立的连接"
    
    # 3. 添加当前用户IP
    echo ""
    echo -e "${CYAN}[4/6] 添加当前用户IP...${NC}"
    if [ -n "$CURRENT_USER_IP" ] && [ "$AUTO_ADD_CURRENT_IP" = "true" ]; then
        local c_seg=$(ip_to_c_segment "$CURRENT_USER_IP")
        iptables -I INPUT -s "$c_seg" -j ACCEPT
        print_success "已添加: $c_seg"
    else
        print_warning "未检测到SSH连接IP或功能未启用"
    fi
    
    # 4. 添加自定义白名单
    if [ ${#CUSTOM_WHITELIST[@]} -gt 0 ]; then
        for ip in "${CUSTOM_WHITELIST[@]}"; do
            iptables -I INPUT -s "$ip" -j ACCEPT
            print_success "已添加: $ip"
        done
    fi
    
    # 5. 添加内网段
    if [ "$ADD_PRIVATE_NETWORKS" = "true" ]; then
        iptables -I INPUT -s 192.168.0.0/16 -j ACCEPT
        iptables -I INPUT -s 10.0.0.0/8 -j ACCEPT
        iptables -I INPUT -s 172.16.0.0/12 -j ACCEPT
        print_success "已添加内网段"
    fi
    
    # 6. 添加百度IP段
    echo ""
    echo -e "${CYAN}[5/6] 添加百度IP段...${NC}"
    if [ ${#BAIDU_SEGMENTS[@]} -gt 0 ]; then
        local count=0
        local total=${#BAIDU_SEGMENTS[@]}
        for segment in "${!BAIDU_SEGMENTS[@]}"; do
            iptables -I INPUT -s "$segment" -j ACCEPT
            count=$((count + 1))
            # 每10个显示一次进度
            if [ $((count % 10)) -eq 0 ] || [ $count -eq $total ]; then
                echo -ne "\r  进度: $count/$total"
            fi
        done
        echo ""
        print_success "已添加 $count 个百度C段"
    else
        print_warning "没有百度IP段需要添加"
    fi
    
    # 7. 默认拒绝所有其他流量
    echo ""
    echo -e "${CYAN}[6/6] 设置默认拒绝规则...${NC}"
    iptables -A INPUT -j DROP
    print_success "已设置默认DROP规则"
    
    print_header "规则应用完成"
}

# 保存iptables规则
save_iptables_rules() {
    print_header "保存iptables规则"
    
    # 根据系统类型保存
    if [ -f /etc/redhat-release ]; then
        # CentOS/RHEL
        if command -v service &> /dev/null; then
            service iptables save 2>/dev/null
        fi
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
        print_success "规则已保存 (CentOS/RHEL)"
        
    elif [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        if [ ! -d /etc/iptables ]; then
            mkdir -p /etc/iptables
        fi
        iptables-save > /etc/iptables/rules.v4
        print_success "规则已保存 (Debian/Ubuntu)"
        
        # 安装 iptables-persistent（如果没有）
        if ! dpkg -l | grep -q iptables-persistent; then
            print_info "建议安装 iptables-persistent 以便开机自动加载规则："
            echo "  apt-get install -y iptables-persistent"
        fi
    else
        # 通用方法
        iptables-save > /etc/iptables.rules
        print_success "规则已保存到 /etc/iptables.rules"
        print_warning "请确保系统启动时会加载此规则文件"
    fi
}

# 查看当前规则
view_current_rules() {
    print_header "当前iptables规则"
    
    echo ""
    echo -e "${CYAN}INPUT链规则统计：${NC}"
    local accept_count=$(iptables -L INPUT -n | grep -c ACCEPT)
    local drop_count=$(iptables -L INPUT -n | grep -c DROP)
    local reject_count=$(iptables -L INPUT -n | grep -c REJECT)
    
    echo "  - ACCEPT规则: $accept_count 条"
    echo "  - DROP规则: $drop_count 条"
    echo "  - REJECT规则: $reject_count 条"
    
    echo ""
    echo -e "${CYAN}INPUT链详细规则（前20条）：${NC}"
    iptables -L INPUT -n --line-numbers | head -25
    
    local total_lines=$(iptables -L INPUT -n | wc -l)
    if [ $total_lines -gt 25 ]; then
        echo "... (还有 $((total_lines - 25)) 行)"
        echo ""
        echo "查看完整规则："
        echo "  iptables -L INPUT -n --line-numbers"
    fi
}

# 清除所有规则
clear_all_rules() {
    print_header "清除所有规则"
    
    echo ""
    print_warning "即将清除所有INPUT规则并恢复默认ACCEPT策略"
    read -p "确认继续？(y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        return 0
    fi
    
    # 备份
    local backup_file="$BACKUP_DIR/before_clear_$(date +%Y%m%d_%H%M%S).rules"
    mkdir -p "$BACKUP_DIR"
    iptables-save > "$backup_file"
    print_success "已备份到: $backup_file"
    
    # 清除
    iptables -F INPUT
    iptables -P INPUT ACCEPT
    
    print_success "已清除所有INPUT规则"
    print_success "已设置默认策略为ACCEPT"
}

# 恢复规则
restore_rules() {
    print_header "恢复iptables规则"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        print_error "没有找到备份文件"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}可用的备份文件：${NC}"
    ls -lht "$BACKUP_DIR"/*.rules 2>/dev/null | nl
    
    echo ""
    read -p "请输入要恢复的备份文件编号（或输入完整路径）: " choice
    
    local restore_file=""
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        restore_file=$(ls -t "$BACKUP_DIR"/*.rules 2>/dev/null | sed -n "${choice}p")
    else
        restore_file="$choice"
    fi
    
    if [ ! -f "$restore_file" ]; then
        print_error "文件不存在: $restore_file"
        return 1
    fi
    
    echo ""
    print_warning "即将恢复规则文件: $restore_file"
    read -p "确认继续？(y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        return 0
    fi
    
    iptables-restore < "$restore_file"
    print_success "规则已恢复"
}

# 显示统计信息
show_statistics() {
    print_header "连接统计"
    
    echo ""
    echo -e "${CYAN}当前连接状态：${NC}"
    netstat -an 2>/dev/null | grep -E ':80|:443' | awk '{print $6}' | sort | uniq -c | while read line; do
        echo "  $line"
    done
    
    echo ""
    echo -e "${CYAN}系统负载：${NC}"
    uptime
    
    echo ""
    echo -e "${CYAN}最近被拒绝的IP（从系统日志）：${NC}"
    if [ -f /var/log/messages ]; then
        grep -i "DROP" /var/log/messages 2>/dev/null | tail -5
    elif [ -f /var/log/syslog ]; then
        grep -i "DROP" /var/log/syslog 2>/dev/null | tail -5
    else
        print_warning "未找到系统日志文件"
    fi
}

################################################################################
# 主菜单
################################################################################

show_menu() {
    clear
    echo "╔════════════════════════════════════════════════╗"
    echo "║     IP 白名单管理脚本 - 一体化版本            ║"
    echo "╚════════════════════════════════════════════════╝"
    echo ""
    echo -e "  ${GREEN}1${NC}. 配置白名单并应用规则（完整流程）"
    echo -e "  ${GREEN}2${NC}. 仅获取百度IP列表（不应用）"
    echo -e "  ${GREEN}3${NC}. 查看当前iptables规则"
    echo -e "  ${GREEN}4${NC}. 保存当前规则"
    echo -e "  ${GREEN}5${NC}. 恢复历史规则"
    echo -e "  ${GREEN}6${NC}. 清除所有规则（恢复默认）"
    echo -e "  ${GREEN}7${NC}. 查看连接统计"
    echo -e "  ${GREEN}8${NC}. 编辑配置"
    echo -e "  ${GREEN}0${NC}. 退出"
    echo ""
    echo "────────────────────────────────────────────────"
}

# 全自动流程（无需交互）
auto_process() {
    print_header "IP白名单全自动配置"
    
    # 检测当前IP
    detect_current_ip
    if [ -n "$CURRENT_USER_IP" ]; then
        print_success "检测到当前SSH连接IP: $CURRENT_USER_IP"
        print_info "将自动添加其C段到白名单"
    else
        print_warning "未检测到SSH连接IP"
    fi
    
    # 获取百度IP
    echo ""
    if [ "$ENABLE_BAIDU_WHITELIST" = "true" ]; then
        fetch_baidu_ips
    else
        print_warning "百度白名单功能已禁用"
    fi
    
    # 显示预览
    echo ""
    show_whitelist_preview
    
    # 自动执行
    echo ""
    echo "────────────────────────────────────────────────"
    print_info "全自动模式：3秒后开始配置..."
    echo "────────────────────────────────────────────────"
    sleep 3
    
    # 应用规则
    apply_iptables_rules
    
    # 自动保存规则
    echo ""
    save_iptables_rules
    
    # 显示结果
    echo ""
    view_current_rules
    
    # 完成
    echo ""
    print_header "配置完成"
    print_success "白名单规则已生效并已保存！"
    echo ""
    print_info "备份文件位置: $BACKUP_DIR"
}

# 主流程（交互式）
main_process() {
    print_header "IP白名单配置向导"
    
    # 检测当前IP
    detect_current_ip
    if [ -n "$CURRENT_USER_IP" ]; then
        print_success "检测到当前SSH连接IP: $CURRENT_USER_IP"
        print_info "将自动添加其C段到白名单"
    else
        print_warning "未检测到SSH连接IP"
        print_warning "如果是远程操作，请确保在CUSTOM_WHITELIST中手动添加你的IP"
    fi
    
    # 获取百度IP
    echo ""
    if [ "$ENABLE_BAIDU_WHITELIST" = "true" ]; then
        fetch_baidu_ips
    else
        print_warning "百度白名单功能已禁用（ENABLE_BAIDU_WHITELIST=false）"
    fi
    
    # 显示预览
    echo ""
    show_whitelist_preview
    
    # 确认
    echo ""
    echo "────────────────────────────────────────────────"
    print_warning "即将应用白名单规则！"
    print_warning "除了上述IP/IP段，其他所有连接将被拒绝！"
    echo ""
    read -p "确认继续？(y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "已取消"
        return 0
    fi
    
    # 应用规则
    apply_iptables_rules
    
    # 保存规则
    echo ""
    read -p "是否保存规则（使其在重启后生效）？(y/n): " save_confirm
    if [[ "$save_confirm" == "y" || "$save_confirm" == "Y" ]]; then
        save_iptables_rules
    fi
    
    # 显示结果
    echo ""
    view_current_rules
    
    # 完成
    echo ""
    print_header "配置完成"
    print_success "白名单规则已生效！"
    echo ""
    print_warning "重要提示："
    echo "  1. 请立即新开SSH窗口测试连接"
    echo "  2. 不要关闭当前窗口，直到确认新连接正常"
    echo "  3. 如果无法连接，在当前窗口运行选项6清除规则"
    echo ""
    print_info "备份文件位置: $BACKUP_DIR"
}

# 编辑配置
edit_config() {
    print_header "编辑配置"
    
    echo ""
    echo "当前配置："
    echo "  - ENABLE_BAIDU_WHITELIST: $ENABLE_BAIDU_WHITELIST"
    echo "  - AUTO_ADD_CURRENT_IP: $AUTO_ADD_CURRENT_IP"
    echo "  - ADD_PRIVATE_NETWORKS: $ADD_PRIVATE_NETWORKS"
    echo "  - CUSTOM_WHITELIST: ${#CUSTOM_WHITELIST[@]} 个"
    echo ""
    
    print_info "要修改配置，请编辑脚本文件的配置区域（第16-35行）"
    echo ""
    echo "使用命令："
    echo "  nano $0"
    echo "  或"
    echo "  vi $0"
    echo ""
    
    read -p "是否现在编辑？(y/n): " edit_confirm
    if [[ "$edit_confirm" == "y" || "$edit_confirm" == "Y" ]]; then
        ${EDITOR:-nano} "$0"
        print_info "编辑完成，请重新运行脚本使配置生效"
        exit 0
    fi
}

################################################################################
# 主程序入口
################################################################################

# 清理函数
cleanup() {
    rm -f "$TEMP_FILE"
}
trap cleanup EXIT

# 检查root权限
check_root

# 如果有命令行参数，执行全自动流程
if [ "$1" = "--auto" ] || [ "$1" = "-a" ]; then
    auto_process
    exit 0
fi

# 交互式菜单
while true; do
    show_menu
    read -p "请选择操作 [0-8]: " choice
    
    case $choice in
        1)
            main_process
            echo ""
            read -p "按回车键继续..."
            ;;
        2)
            detect_current_ip
            fetch_baidu_ips
            echo ""
            print_info "已获取 ${#BAIDU_SEGMENTS[@]} 个百度IP段"
            echo ""
            read -p "按回车键继续..."
            ;;
        3)
            view_current_rules
            echo ""
            read -p "按回车键继续..."
            ;;
        4)
            save_iptables_rules
            echo ""
            read -p "按回车键继续..."
            ;;
        5)
            restore_rules
            echo ""
            read -p "按回车键继续..."
            ;;
        6)
            clear_all_rules
            echo ""
            read -p "按回车键继续..."
            ;;
        7)
            show_statistics
            echo ""
            read -p "按回车键继续..."
            ;;
        8)
            edit_config
            ;;
        0)
            print_info "退出程序"
            exit 0
            ;;
        *)
            print_error "无效选择，请重新输入"
            sleep 2
            ;;
    esac
done

