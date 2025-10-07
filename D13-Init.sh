#!/usr/bin/env bash
# Trixie_Init_202510_idempotent.sh
# 目标：
# 1) 非交互、可重复执行（幂等），失败处具备重试；
# 2) 保留原脚本安装的全部组件与配置，结果不变；
# 3) 重点修复 certbot 可能“被忽略/未就绪”的问题（snapd 就绪检测 + 重试 + 显式软链）。
# 4) 增加阶段性彩色输出和最终汇总。

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

#-----------------------------
# 1. 增强的输出与汇总功能
#-----------------------------
# 颜色定义
COLOR_CYAN='\033[1;36m'
COLOR_RED='\033[1;31m'
COLOR_GREEN='\033[1;32m'
COLOR_NC='\033[0m' # 无颜色

# 用于最终汇总的日志数组
SUCCESS_LOG=()
ERROR_LOG=()
CURRENT_STAGE=""

# 打印阶段性任务标题 (天蓝色)
log_task() {
    CURRENT_STAGE="$1"
    printf "\n${COLOR_CYAN}▸▸▸ [阶段开始] %s...${COLOR_NC}\n" "$CURRENT_STAGE"
}

# 打印最终的执行汇总报告
print_summary() {
    printf "\n\n${COLOR_CYAN}======================== 执行汇总 ========================${COLOR_NC}\n"
    if [ ${#SUCCESS_LOG[@]} -gt 0 ]; then
        printf "${COLOR_GREEN}✔ 成功完成的阶段:${COLOR_NC}\n"
        for task in "${SUCCESS_LOG[@]}"; do
            printf "  - %s\n" "$task"
        done
    fi

    if [ ${#ERROR_LOG[@]} -gt 0 ]; then
        printf "\n${COLOR_RED}✘ 发现问题的阶段:${COLOR_NC}\n"
        for task in "${ERROR_LOG[@]}"; do
            printf "  - %s\n" "$task"
        done
        printf "\n${COLOR_RED}脚本执行期间出现问题，请检查以上红色错误信息。${COLOR_NC}\n"
    else
        printf "\n${COLOR_GREEN}✔ 所有阶段均已成功完成。可以重复执行本脚本以验证幂等性。${COLOR_NC}\n"
    fi
    printf "${COLOR_CYAN}==========================================================${COLOR_NC}\n"
}


#-----------------------------
# 2. 基础函数 (已修改以集成新日志)
#-----------------------------
log()   { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
warn()  { printf '[%s] [WARN] %s\n' "$(date +'%F %T')" "$*" >&2; }

# 错误输出 (红色)，并记录到汇总
error() {
    local msg="$*"
    printf "${COLOR_RED}[%s] [ERROR] %s${COLOR_NC}\n" "$(date +'%F %T')" "$msg" >&2
    ERROR_LOG+=("阶段 '$CURRENT_STAGE': $msg")
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "请以 root 身份运行。"
    exit 1
  fi
}

# 重试函数，在最终失败时调用 error() 记录日志
retry() {
  local tries="$1"; shift
  local delay="$1"; shift
  local attempt=1
  until "$@"; do
    local rc=$?
    if (( attempt >= tries )); then
      error "命令在 ${tries} 次尝试后最终失败 (退出码: ${rc}): $*"
      return "$rc"
    fi
    warn "命令失败（第 ${attempt} 次），${delay}s 后重试：$*"
    sleep "$delay"
    ((attempt++))
  done
}

apt_update_once() {
  if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]] || \
     [[ $(find /var/lib/apt/periodic/update-success-stamp -mmin +30 2>/dev/null || true) ]]; then
    log "正在更新 APT 软件包索引..."
    retry 3 5 apt-get update -y
  else
    log "APT 索引近期已更新，跳过 apt-get update。"
  fi
}

ensure_line_in_file() {
  local line="$1"; local file="$2"
  grep -Fxq -- "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

set_php_ini_kv() {
  local file="$1" key="$2" val="$3"
  if [[ -f "$file" ]]; then
    if grep -qE "^[; ]*${key}[[:space:]]*=" "$file"; then
      sed -i "s|^[; ]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
    else
      echo "${key} = ${val}" >> "$file"
    fi
  else
    warn "未发现 $file，跳过 ${key} 设置。"
  fi
}

#-----------------------------
# 3. 脚本执行主体
#-----------------------------

# 阶段 0: 预检
log_task "预检与环境检查"
require_root
log "开始执行（幂等/非交互模式）……"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 1: 系统更新与时区
log_task "系统更新与时区设置"
apt_update_once
retry 3 5 apt-get -o Dpkg::Options::="--force-confold" -y upgrade
if timedatectl status >/dev/null 2>&1; then
  timedatectl set-timezone Asia/Shanghai || warn "设置时区失败（可能容器环境不支持 timedatectl），忽略。"
fi
log "系统更新与时区设置完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 2: 基础工具
log_task "安装基础工具与 Python 包"
apt_update_once
retry 3 5 apt-get install -y --no-install-recommends \
  vim nano gcc rsync p7zip-full unzip curl wget sshpass nload net-tools tree iftop sudo nmap make git apache2-utils expect yq dnsutils \
  apt-transport-https lsb-release ca-certificates gnupg
retry 3 5 apt-get install -y python3-pip python3-setuptools
#python3 -m pip install --break-system-packages -q \
#  python-docx openpyxl python-pptx PyMuPDF xlrd pyth
#python3 -m pip install --break-system-packages -q openai
log "基础工具安装完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 3: Node.js (nvm) + pm2
log_task "配置 Node.js (nvm) 与 pm2"
NVM_VERSION="v0.40.2"
export NVM_DIR="/root/.nvm"
if [[ ! -d "$NVM_DIR" ]]; then
  retry 3 5 bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
fi
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null || echo)" != v22.* ]]; then
  retry 3 5 nvm install 22
fi
nvm use 22 >/dev/null
nvm alias default 22 >/dev/null
retry 3 5 npm install -g pm2
ln -sf "$(command -v node)" /usr/local/bin/node
ln -sf "$(command -v npm)"  /usr/local/bin/npm
ln -sf "$(command -v pm2)"  /usr/local/bin/pm2
cat >/etc/profile.d/nvm.sh <<'EOF'
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF
log "Node.js 环境配置完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 4: PHP 源 & PHP/扩展 & Composer
log_task "配置 PHP 源、安装 Nginx/PHP 与 Composer"
if [[ ! -f /etc/apt/trusted.gpg.d/php.gpg ]]; then
  retry 3 5 wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
fi
if [[ ! -f /etc/apt/sources.list.d/sury-php.list ]]; then
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
fi
apt_update_once
retry 3 5 apt-get install -y --no-install-recommends \
  acl curl fping git graphviz mtr-tiny nginx-full nmap \
  php-cli php-curl php-fpm php-gd php-gmp php-json php-mbstring php-mysql php-snmp php-xml php-zip \
  python3-dotenv python3-pymysql python3-redis rrdtool snmp snmpd whois
if ! command -v composer >/dev/null 2>&1; then
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f composer-setup.php
fi
log "Nginx, PHP 及 Composer 安装配置完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 5: snapd 与 certbot
log_task "安装与配置 snapd 及 certbot"
retry 3 5 apt-get install -y snapd
systemctl enable --now snapd >/dev/null 2>&1 || true
systemctl start snapd.socket >/dev/null 2>&1 || true
if command -v snap >/dev/null 2>&1; then
  log "等待 snap 系统服务就绪..."
  timeout 120 bash -c 'until snap wait system seed >/dev/null 2>&1; do sleep 2; done' || warn "snap seed 等待超时，继续尝试安装。"
  retry 3 10 snap install core
  retry 3 10 snap refresh core
  if ! snap list 2>/dev/null | grep -q '^certbot\s'; then
    retry 5 10 snap install --classic certbot
  fi
  ln -sf /snap/bin/certbot /usr/bin/certbot
  if ! command -v certbot >/dev/null 2>&1; then
    error "certbot 未能正确安装到 PATH。"
    exit 1
  fi
  log "Certbot 安装成功。"
else
  error "snap 命令不可用，无法通过 snap 安装 certbot。"
  exit 1
fi
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 6: SNMP 配置
log_task "配置 SNMP 服务"
retry 3 5 apt-get install -y snmpd snmp
systemctl stop snmpd || true
cat > /etc/snmp/snmpd.conf <<'EOF'
sysLocation    Foundry
sysContact     Eiswein.OS@outlook.com
sysServices    72
agentAddress   udp:161,udp6:[::1]:161
view all included .1 80
rouser AzureEC priv
EOF
if ! grep -q 'AzureEC' /var/lib/snmp/snmpd.conf 2>/dev/null; then
  net-snmp-create-v3-user -ro -A "publicAzure+++++++" -a SHA -X "publicAzure+++++++" -x AES AzureEC
fi
systemctl restart snmpd
log "SNMP 配置已更新并重启。尝试 snmpwalk 自检……"
snmpwalk -v3 -u AzureEC -l authPriv -a SHA -A 'publicAzure+++++++' -x AES -X 'publicAzure+++++++' localhost \
  || warn "snmpwalk 自检失败，请稍后手动核查配置。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 7: MariaDB 11.8.2
log_task "安装 MariaDB 11.8.2"
install -d -m 0755 /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/mariadb-release-signing-keyring.gpg ]]; then
  curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/mariadb-release-signing-keyring.gpg
fi
if [[ ! -f /etc/apt/sources.list.d/mariadb.list ]] || ! grep -q 'mariadb-11.8.2' /etc/apt/sources.list.d/mariadb.list; then
  tee /etc/apt/sources.list.d/mariadb.list >/dev/null <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/mariadb-release-signing-keyring.gpg] https://archive.mariadb.org/mariadb-11.8.2/repo/debian bookworm main
EOF
fi
apt_update_once
retry 3 5 apt-get install -y mariadb-server mariadb-client
systemctl enable --now mariadb
log "MariaDB 安装完成。版本信息：$(mariadb --version || true)"
log "重要提示：请手动运行 'mariadb-secure-installation' 来加固您的数据库。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 8: PHP 8.4 ini 调优
log_task "调优 PHP 8.4 配置 (ini)"
set_php_ini_kv /etc/php/8.4/cli/php.ini upload_max_filesize  "8000M"
set_php_ini_kv /etc/php/8.4/cli/php.ini post_max_size        "8000M"
set_php_ini_kv /etc/php/8.4/cli/php.ini memory_limit         "800M"
set_php_ini_kv /etc/php/8.4/cli/php.ini max_execution_time   "300"
set_php_ini_kv /etc/php/8.4/cli/php.ini max_input_time       "300"
set_php_ini_kv /etc/php/8.4/cli/php.ini max_file_uploads     "500"
set_php_ini_kv /etc/php/8.4/fpm/php.ini upload_max_filesize "8000M"
set_php_ini_kv /etc/php/8.4/fpm/php.ini post_max_size        "8000M"
set_php_ini_kv /etc/php/8.4/fpm/php.ini memory_limit         "800M"
set_php_ini_kv /etc/php/8.4/fpm/php.ini max_execution_time   "300"
set_php_ini_kv /etc/php/8.4/fpm/php.ini max_input_time       "300"
set_php_ini_kv /etc/php/8.4/fpm/php.ini max_file_uploads     "500"
systemctl restart php8.4-fpm 2>/dev/null || warn "php8.4-fpm 服务不存在或未安装，已跳过重启。"
log "PHP.ini 配置调优完成。"
SUCCESS_LOG+=("$CURRENT_STAGE")

#-----------------------------
# 4. 收尾
#-----------------------------
print_summary
