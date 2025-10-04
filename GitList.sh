#!/bin/bash

#
# 描述:
#   该脚本用于列出用户的 GitHub 仓库及其最后更新时间。
#   输出结果按时间逆序排列（最新的在最后）。
#   当天更新的仓库会以天蓝色高亮显示（以北京时间判定“当天”）。
#
# 使用方法:
#   ./get_repos.sh <your_github_api_token>
#
# 依赖:
#   - curl
#   - jq
#   - tac
#

# --- 检查参数 ---
if [[ -z "$1" ]]; then
  echo "错误：缺少 GitHub API 令牌。" >&2
  echo "用法: $0 <your_github_api_token>" >&2
  exit 1
fi

# --- 配置 ---
API_TOKEN="$1"

# 使用北京时间计算“今天”
TODAY=$(TZ=Asia/Shanghai date +%Y-%m-%d)

# 颜色设置：优先使用 256 色的天蓝色(38;5;39)，不支持则退回青色
if [[ -t 1 ]] && command -v tput >/devnull 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 256 ]]; then
  CYAN='\033[38;5;39m'   # DeepSkyBlue1
else
  CYAN='\033[0;36m'      # 退回普通青色
fi
NC='\033[0m'

# --- 主逻辑 ---
echo "正在从 GitHub API 获取仓库列表..."
echo "------------------------------------------------------------"

# 保持原有排序：API 按更新时间降序，随后用 tac 反转，使“最新在最后”
# 新增分页遍历；新增最终输出编号（1..N）
(
  page=1
  per_page=100
  while : ; do
    resp="$(
      curl -s \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $API_TOKEN" \
        "https://api.github.com/user/repos?per_page=${per_page}&page=${page}&sort=updated&direction=desc"
    )" || exit 1

    count=$(jq 'length' <<<"$resp")
    [[ "$count" -eq 0 ]] && break

    jq -r '.[] | "\(.name)\t\(.updated_at)"' <<<"$resp" | \
    while IFS=$'\t' read -r name updated_at; do
      [[ -z "$name" ]] && continue

      # 以北京时间判断是否为“当天”
      repo_date_bj=$(TZ=Asia/Shanghai date -d "$updated_at" "+%Y-%m-%d" 2>/dev/null || echo "${updated_at%%T*}")

      # 保持原有显示格式：本地时区格式化为 YYYYMMDD-HHMM（不改变列结构）
      formatted_ts=$(date -d "$updated_at" "+%Y%m%d-%H%M")

      line=$(printf "%-45s %s" "$name" "$formatted_ts")

      if [[ "$repo_date_bj" == "$TODAY" ]]; then
        # 当天：天蓝色高亮（行内着色）
        echo -e "${CYAN}${line}${NC}"
      else
        echo "$line"
      fi
    done

    [[ "$count" -lt "$per_page" ]] && break
    page=$((page + 1))
  done
) | tac | awk '{printf("%5d. %s\n", NR, $0)}'

echo "------------------------------------------------------------"
echo "完成。"
