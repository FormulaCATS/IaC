#!/bin/bash

# 检查是否安装了 certbot
if ! command -v certbot >/dev/null 2>&1; then
    echo -e "\x1b[91m错误：未检测到 certbot，请先安装 certbot。\x1b[0m" >&2
    exit 1
fi

# --- 颜色定义 ---
SKY_BLUE="\x1b[96m"
YELLOW="\x1b[33m"
GREEN="\x1b[32m"
RED="\x1b[31m"
NO_COLOR="\x1b[0m"

# --- 脚本主标题 ---
echo ""
echo -e "${SKY_BLUE}========================================================================${NO_COLOR}"
echo -e "${SKY_BLUE}                     Certbot SSL 证书状态检查                           ${NO_COLOR}"
echo -e "${SKY_BLUE}========================================================================${NO_COLOR}"
echo ""

# --- 打印表格 ---
# 打印表头
echo -e "${SKY_BLUE}┌──────────────────────────────────┬─────────────┬─────────────────┐${NO_COLOR}"
printf "${SKY_BLUE}│ %-32s │ %-11s │ %-15s │${NO_COLOR}\n" "DOMAIN" "EXPIRY DATE" "REMAIN(DAYS)"
echo -e "${SKY_BLUE}├──────────────────────────────────┼─────────────┼─────────────────┤${NO_COLOR}"

# 获取当前时间戳
CURRENT_TS=$(date +%s)

# --- 核心逻辑：先解析，后格式化 ---

# 1. awk 负责解析和计算，输出用分号分隔的纯数据: domain;expiry_date;remaining_string;status
certbot certificates 2>/dev/null | awk -v current_ts="$CURRENT_TS" '
BEGIN {
    RS = "Certificate Name:"
    FS = "\n"
}
NR > 1 {
    # 清理域名两端的空格
    gsub(/^[ \t]+|[ \t]+$/, "", $1)
    domain = $1
    
    expiry_display = "Not Found"
    remaining_str = "UNKNOWN"
    status = "UNKNOWN" # SAFE, WARNING, EXPIRED, UNKNOWN

    for (i=2; i<=NF; i++) {
        if ($i ~ /Expiry Date:/) {
            # 提取 YYYY-MM-DD 用于显示
            match($i, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)
            expiry_display = substr($i, RSTART, RLENGTH)
            
            # 提取完整日期用于计算
            match($i, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)
            calc_date = substr($i, RSTART, RLENGTH)
            gsub(/[-:]/, " ", calc_date)
            expiry_ts = mktime(calc_date)
            
            diff_sec = expiry_ts - current_ts
            
            if (diff_sec < 0) {
                remaining_str = "EXPIRED"
                status = "EXPIRED"
            } else {
                remaining_days = int(diff_sec / 86400)
                remaining_str = remaining_days "d"
                if (remaining_days <= 30) {
                    status = "WARNING"
                } else {
                    status = "SAFE"
                }
            }
            break
        }
    }
    printf "%s;%s;%s;%s\n", domain, expiry_display, remaining_str, status
}' | \
# 2. while 循环读取纯数据，负责着色和保证对齐
while IFS=';' read -r domain expiry remain status; do
    REMAIN_COLOR=$SKY_BLUE # 默认颜色
    case "$status" in
        "SAFE")    REMAIN_COLOR=$GREEN ;;
        "WARNING") REMAIN_COLOR=$YELLOW ;;
        "EXPIRED") REMAIN_COLOR=$RED ;;
    esac

    # 先填充文本到指定宽度，再给填充好的文本块上色
    padded_domain=$(printf "%-32s" "$domain")
    padded_expiry=$(printf "%-11s" "$expiry")
    padded_remain=$(printf "%-15s" "$remain")

    # 组合输出，确保对齐
    echo -e "${SKY_BLUE}│${NO_COLOR} ${YELLOW}${padded_domain} ${SKY_BLUE}│${NO_COLOR} ${SKY_BLUE}${padded_expiry} ${SKY_BLUE}│${NO_COLOR} ${REMAIN_COLOR}${padded_remain} ${SKY_BLUE}│${NO_COLOR}"
done

# 打印表尾
echo -e "${SKY_BLUE}└──────────────────────────────────┴─────────────┴─────────────────┘${NO_COLOR}"
echo ""

