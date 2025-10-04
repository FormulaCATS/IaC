#!/bin/bash

# 检查是否安装了 certbot
if ! command -v certbot >/dev/null 2>&1; then
    echo -e "\x1b[91m错误：未检测到 certbot，请先安装 certbot。\x1b[0m" >&2
    exit 1
fi

# 颜色定义：
#   SKY_BLUE  = Bright Cyan (ANSI 96)
#   YELLOW    = Yellow (ANSI 33)
#   GREEN     = Green (ANSI 32)
#   NO_COLOR  = 重置颜色 (ANSI 0)
SKY_BLUE="\x1b[96m"
YELLOW="\x1b[33m"
GREEN="\x1b[32m"
NO_COLOR="\x1b[0m"

# 获取当前时间戳（以秒为单位）
CURRENT_TS=$(date +%s)

# 打印表头（天蓝色）
#   第一列宽度 30 字符，第二列宽度 25 字符，第三列宽度 10 字符
printf "${SKY_BLUE}%-30s %-25s %-10s${NO_COLOR}\n" "DOMAIN" "EXPIRY DATE" "REMAIN(DAYS)"
printf "${SKY_BLUE}%-30s %-25s %-10s${NO_COLOR}\n" "------------------------------" "-------------------------" "----------"

# 从 certbot 输出中抽取“Certificate Name”与“Expiry Date”行，逐对处理
certbot certificates | grep -E "Certificate Name|Expiry Date" | \
while IFS= read -r line; do
    # 如果是“Certificate Name”行
    if echo "$line" | grep -q "Certificate Name:"; then
        # 提取冒号后面的域名（去除行首空白）
        DOMAIN_NAME=$(echo "$line" | sed -E 's/^\s*Certificate Name:\s*(.*)$/\1/')
        # 保存到变量，等待下一个 Expiry Date 行
        CUR_DOMAIN="$DOMAIN_NAME"
    fi

    # 如果是“Expiry Date”行
    if echo "$line" | grep -q "Expiry Date:"; then
        # 提取完整的日期字符串（格式：YYYY-MM-DD HH:MM:SS±TZ）
        EXPIRY_FULL=$(echo "$line" | sed -E 's/^\s*Expiry Date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\+[0-9]{2}:[0-9]{2}).*$/\1/')

        # 计算过期日期的时间戳（秒）
        EXPIRY_TS=$(date -d "$EXPIRY_FULL" +%s 2>/dev/null)
        if [ -z "$EXPIRY_TS" ]; then
            # 如果无法解析日期，则标记为未知
            REMAINING_STR="UNKNOWN"
        else
            # 计算剩余秒数并转换为天数（向下取整）
            DIFF_SEC=$((EXPIRY_TS - CURRENT_TS))
            if [ "$DIFF_SEC" -lt 0 ]; then
                REMAINING_STR="EXPIRED"
            else
                REMAINING_DAYS=$((DIFF_SEC / 86400))
                REMAINING_STR="${REMAINING_DAYS}d"
            fi
        fi

        # 打印该行：域名（黄），有效期（绿），剩余（天蓝）
        printf "${YELLOW}%-30s${NO_COLOR} ${GREEN}%-25s${NO_COLOR} ${SKY_BLUE}%-10s${NO_COLOR}\n" \
            "$CUR_DOMAIN" "$EXPIRY_FULL" "$REMAINING_STR"
    fi
done
