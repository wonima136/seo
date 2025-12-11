#!/bin/bash
################################################################################
# 被拦截IP后台监控脚本 - 长期运行版本
# 功能：
#   - 自动启用iptables LOG规则
#   - 实时监控被拦截的IP
#   - 按日期自动保存日志文件
#   - 支持长期后台运行（配合screen使用）
#
# 使用方法：
#   1. screen -S monitor
#   2. sudo ./monitor_blocked.sh
#   3. Ctrl+A+D 挂后台
#
# 恢复查看：screen -r monitor
################################################################################

# 配置
DATA_DIR="/root/data"
LOG_PREFIX="BLOCKED_IP: "
CHECK_INTERVAL=1  # 每秒检查一次日志

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

################################################################################
# 初始化
################################################################################

# 检查root权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 sudo 运行此脚本${NC}"
    exit 1
fi

# 创建数据目录
mkdir -p "$DATA_DIR"
echo -e "${GREEN}✓${NC} 数据目录: $DATA_DIR"

# 获取当前日期文件
get_today_file() {
    echo "$DATA_DIR/$(date +%Y-%m-%d).txt"
}

# 确定系统日志文件
detect_log_file() {
    if [ -f /var/log/kern.log ]; then
        echo "/var/log/kern.log"
    elif [ -f /var/log/messages ]; then
        echo "/var/log/messages"
    elif [ -f /var/log/syslog ]; then
        echo "/var/log/syslog"
    else
        echo ""
    fi
}

################################################################################
# iptables LOG规则管理
################################################################################

# 检查LOG规则是否存在
check_log_rule() {
    iptables -L INPUT -n | grep -q "LOG.*$LOG_PREFIX"
}

# 添加LOG规则
add_log_rule() {
    echo -e "${YELLOW}检查iptables LOG规则...${NC}"
    
    if check_log_rule; then
        echo -e "${GREEN}✓${NC} LOG规则已存在"
        return 0
    fi
    
    echo -e "${YELLOW}添加iptables LOG规则...${NC}"
    
    # 查找DROP规则的位置
    local drop_line=$(iptables -L INPUT --line-numbers -n | grep "DROP.*all" | tail -1 | awk '{print $1}')
    
    if [ -z "$drop_line" ]; then
        echo -e "${RED}✗${NC} 未找到DROP规则，请先配置白名单"
        echo -e "${YELLOW}提示：运行 whitelist_manager.sh 配置白名单${NC}"
        exit 1
    fi
    
    # 在DROP规则前插入LOG规则（限速：10条/分钟，突发20条）
    iptables -I INPUT $drop_line -m limit --limit 10/min --limit-burst 20 -j LOG --log-prefix "$LOG_PREFIX" --log-level 4
    
    echo -e "${GREEN}✓${NC} LOG规则已添加（限速：10条/分钟）"
    echo ""
}

################################################################################
# 核心监控功能
################################################################################

# 格式化输出
format_log_line() {
    local src_ip="$1"
    local dst_port="$2"
    local proto="$3"
    local src_port="$4"
    
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # 判断服务类型
    local service=""
    case $dst_port in
        22) service="SSH" ;;
        80) service="HTTP" ;;
        443) service="HTTPS" ;;
        3306) service="MySQL" ;;
        3389) service="RDP" ;;
        21) service="FTP" ;;
        23) service="Telnet" ;;
        25) service="SMTP" ;;
        *) service="-" ;;
    esac
    
    # 输出格式：时间|源IP|协议|源端口|目标端口|服务
    echo "$timestamp|$src_ip|$proto|$src_port|$dst_port|$service"
}

# 主监控循环
start_monitoring() {
    local system_log=$(detect_log_file)
    
    if [ -z "$system_log" ]; then
        echo -e "${RED}✗${NC} 未找到系统日志文件"
        exit 1
    fi
    
    echo -e "${GREEN}✓${NC} 系统日志: $system_log"
    echo ""
    
    echo "════════════════════════════════════════════════════════════════"
    echo -e "${CYAN}开始监控被拦截的IP${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo -e "数据目录: ${GREEN}$DATA_DIR${NC}"
    echo -e "当前日志: ${GREEN}$(get_today_file)${NC}"
    echo ""
    echo -e "${YELLOW}提示: 按 Ctrl+C 停止监控${NC}"
    echo -e "${YELLOW}提示: 按 Ctrl+A+D 挂到后台（screen模式）${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    # 显示表头
    printf "${CYAN}%-19s %-18s %-6s %-8s %-8s %-10s${NC}\n" "时间" "源IP" "协议" "源端口" "目标端口" "服务"
    echo "────────────────────────────────────────────────────────────────"
    
    # 记录已处理的日志行（避免重复）
    local last_processed=""
    local current_date=$(date +%Y-%m-%d)
    local today_file=$(get_today_file)
    local line_count=0
    
    # 添加日志文件头（如果是新文件）
    if [ ! -f "$today_file" ]; then
        echo "# 被拦截IP日志 - $(date +%Y-%m-%d)" > "$today_file"
        echo "# 格式: 时间|源IP|协议|源端口|目标端口|服务" >> "$today_file"
        echo "# ────────────────────────────────────────────────────────────" >> "$today_file"
    fi
    
    # 实时监控日志
    tail -F -n 0 "$system_log" 2>/dev/null | while read -r line; do
        # 检查是否跨天（需要切换日志文件）
        local new_date=$(date +%Y-%m-%d)
        if [ "$new_date" != "$current_date" ]; then
            echo ""
            echo -e "${YELLOW}══════════════════════════════════════════${NC}"
            echo -e "${YELLOW}日期变更: $current_date → $new_date${NC}"
            echo -e "${YELLOW}══════════════════════════════════════════${NC}"
            echo ""
            
            current_date="$new_date"
            today_file=$(get_today_file)
            line_count=0
            
            # 新建日志文件头
            echo "# 被拦截IP日志 - $(date +%Y-%m-%d)" > "$today_file"
            echo "# 格式: 时间|源IP|协议|源端口|目标端口|服务" >> "$today_file"
            echo "# ────────────────────────────────────────────────────────────" >> "$today_file"
            
            # 重新显示表头
            printf "${CYAN}%-19s %-18s %-6s %-8s %-8s %-10s${NC}\n" "时间" "源IP" "协议" "源端口" "目标端口" "服务"
            echo "────────────────────────────────────────────────────────────────"
        fi
        
        # 检查是否包含被拦截的日志
        if echo "$line" | grep -q "$LOG_PREFIX"; then
            # 解析日志信息
            local src_ip=$(echo "$line" | grep -oP 'SRC=\K[0-9.]+' | head -1)
            local dst_port=$(echo "$line" | grep -oP 'DPT=\K[0-9]+' | head -1)
            local src_port=$(echo "$line" | grep -oP 'SPT=\K[0-9]+' | head -1)
            local proto=$(echo "$line" | grep -oP 'PROTO=\K[A-Z]+' | head -1)
            
            # 确保解析到了IP
            if [ -n "$src_ip" ]; then
                # 格式化日志行
                local log_line=$(format_log_line "$src_ip" "$dst_port" "$proto" "$src_port")
                
                # 写入文件
                echo "$log_line" >> "$today_file"
                line_count=$((line_count + 1))
                
                # 提取字段用于显示
                local timestamp=$(echo "$log_line" | cut -d'|' -f1)
                local display_time=$(echo "$timestamp" | cut -d' ' -f2)
                local service=$(echo "$log_line" | cut -d'|' -f6)
                
                # 彩色输出到终端
                printf "${BLUE}%-19s${NC} ${RED}%-18s${NC} ${CYAN}%-6s${NC} ${YELLOW}%-8s${NC} ${GREEN}%-8s${NC} ${MAGENTA}%-10s${NC}\n" \
                    "$display_time" "$src_ip" "$proto" "$src_port" "$dst_port" "$service"
                
                # 每100条显示一次统计
                if [ $((line_count % 100)) -eq 0 ]; then
                    echo -e "${YELLOW}[统计] 今日已拦截: $line_count 次${NC}"
                fi
            fi
        fi
    done
}

################################################################################
# 信号处理
################################################################################

# 优雅退出
cleanup() {
    echo ""
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo -e "${YELLOW}监控已停止${NC}"
    echo "════════════════════════════════════════════════════════════════"
    
    local today_file=$(get_today_file)
    if [ -f "$today_file" ]; then
        local total_lines=$(grep -v "^#" "$today_file" | wc -l)
        local unique_ips=$(grep -v "^#" "$today_file" | cut -d'|' -f2 | sort -u | wc -l)
        
        echo -e "今日日志: ${GREEN}$today_file${NC}"
        echo -e "拦截记录: ${GREEN}$total_lines${NC} 条"
        echo -e "唯一IP数: ${YELLOW}$unique_ips${NC} 个"
    fi
    
    echo ""
    echo -e "${CYAN}查看日志：${NC}"
    echo "  cat $today_file"
    echo "  或"
    echo "  tail -f $today_file"
    
    echo ""
    echo -e "${CYAN}分析统计：${NC}"
    echo "  # 查看TOP 10攻击IP"
    echo "  grep -v '^#' $today_file | cut -d'|' -f2 | sort | uniq -c | sort -rn | head -10"
    echo ""
    echo "  # 查看TOP 10攻击端口"
    echo "  grep -v '^#' $today_file | cut -d'|' -f5 | sort | uniq -c | sort -rn | head -10"
    
    echo "════════════════════════════════════════════════════════════════"
    exit 0
}

trap cleanup SIGINT SIGTERM

################################################################################
# 主程序
################################################################################

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "          被拦截IP监控系统 - 后台运行版本"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. 添加LOG规则
add_log_rule

# 2. 开始监控
start_monitoring

