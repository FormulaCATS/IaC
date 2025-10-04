#!/bin/bash
# 目标：为指定的域名自动化创建 Nginx 站点、申请 SSL 证书并应用安全配置。
# 特性：
# 1) 分阶段彩色输出，过程清晰。
# 2) 具备幂等性，可重复安全执行。
# 3) 包含最终执行汇总报告。
# 4) 优化了 Nginx 配置，增强了安全性。

set -euo pipefail

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
DOMAIN=""

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
        printf "\n${COLOR_GREEN}✔ 网站配置成功！域名 '$DOMAIN' 现在应该可以通过 HTTPS 访问。${COLOR_NC}\n"
    fi
    printf "${COLOR_CYAN}==========================================================${COLOR_NC}\n"
}

#-----------------------------
# 2. 基础函数
#-----------------------------
log()   { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
warn()  { printf '[%s] [WARN] %s\n' "$(date +'%F %T')" "$*" >&2; }

# 错误输出 (红色)，并记录到汇总
error() {
    local msg="$*"
    printf "${COLOR_RED}[%s] [ERROR] %s${COLOR_NC}\n" "$(date +'%F %T')" "$msg" >&2
    if [ -n "$CURRENT_STAGE" ]; then
        ERROR_LOG+=("阶段 '$CURRENT_STAGE': $msg")
    else
        ERROR_LOG+=("预检阶段: $msg")
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "必需命令 '$1' 未找到。请先安装它。"
        print_summary
        exit 1
    fi
}

#=============================
# 3. 脚本执行主体
#=============================

# 阶段 0: 预检与参数验证
log_task "预检与参数验证"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  error "请以 root 身份运行此脚本。"
  print_summary
  exit 1
fi

if [ -z "$1" ]; then
  error "用法: $0 your_domain.com"
  print_summary
  exit 1
fi

check_command "nginx"
check_command "certbot"
check_command "curl"

DOMAIN=$1
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
PHP_VERSION="php8.4" # 根据系统安装的PHP版本进行调整
log "域名: $DOMAIN"
log "网站根目录: $WEB_ROOT"
log "Nginx 配置文件: $NGINX_CONF"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 1: 创建网站目录
log_task "创建网站根目录"
mkdir -p "$WEB_ROOT"
chown www-data:www-data "$WEB_ROOT"
log "目录 '$WEB_ROOT' 创建并设置权限成功。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 检查证书是否存在，决定是否需要申请
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    warn "检测到 '$DOMAIN' 的 SSL 证书已存在，将跳过证书申请步骤。"
    SUCCESS_LOG+=("为 Certbot 配置临时 Nginx - 已跳过")
    SUCCESS_LOG+=("申请 SSL 证书 (Certbot) - 已跳过")
else
    # 阶段 2: 临时 Nginx 配置
    log_task "为 Certbot 配置临时 Nginx"
    log "创建用于 Let's Encrypt 验证的临时 Nginx 配置..."
    cat > "$NGINX_CONF" <<- EOM
server {
    listen 80;
    server_name $DOMAIN;
    root $WEB_ROOT;
    location /.well-known/acme-challenge/ { allow all; }
    location / { try_files \$uri \$uri/ =404; }
}
EOM
    if [ ! -L "/etc/nginx/sites-enabled/$DOMAIN" ]; then
        ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/
    fi
    log "测试并重载 Nginx 配置..."
    nginx -t || { error "Nginx 配置测试失败。"; print_summary; exit 1; }
    systemctl reload nginx || { error "Nginx 重载失败。"; print_summary; exit 1; }
    log "临时配置已应用。"
    SUCCESS_LOG+=("$CURRENT_STAGE")

    # 阶段 3: 申请 SSL 证书
    log_task "申请 SSL 证书 (Certbot)"
    log "开始使用 certbot 申请证书，请稍候..."
    certbot certonly --webroot -w "$WEB_ROOT" -d "$DOMAIN" --agree-tos --email root@omnios.world --non-interactive || {
        error "Certbot 证书申请失败。请检查域名解析和防火墙设置。"
        print_summary
        exit 1
    }
    log "SSL 证书申请成功！"
    SUCCESS_LOG+=("$CURRENT_STAGE")
fi

# 阶段 4: 最终 Nginx 配置
log_task "配置最终的 Nginx (HTTP & HTTPS)"
log "正在生成最终的 Nginx 配置文件..."
cat > "$NGINX_CONF" <<- EOM
server {
    listen 80;
    server_name $DOMAIN;
    # 将所有HTTP请求重定向到HTTPS，但为证书续订保留验证路径
    location /.well-known/acme-challenge/ {
        root $WEB_ROOT;
        allow all;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root $WEB_ROOT;
    client_max_body_size 8000M;
    index index.php index.html;

    # SSL 优化配置 (由 Certbot 生成)
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    access_log /var/log/nginx/$DOMAIN-access.log;
    error_log /var/log/nginx/$DOMAIN-error.log;

    # 增强安全性的 Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php(?:\$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:/var/run/php/$PHP_VERSION-fpm.sock;
    }

    # 拒绝访问隐藏文件
    location ~ /\. {
        deny all;
    }
}
EOM
log "测试并重载 Nginx 最终配置..."
nginx -t || { error "最终 Nginx 配置测试失败。"; print_summary; exit 1; }
systemctl reload nginx || { error "Nginx 重载失败。"; print_summary; exit 1; }
log "最终配置已应用。"
SUCCESS_LOG+=("$CURRENT_STAGE")

# 阶段 5: 验证
log_task "验证 HTTPS 连接"
log "等待 5 秒以确保 Nginx 完全重载..."
sleep 5
log "使用 curl 测试 HTTPS 连接..."
if curl -s --head --fail "https://$DOMAIN/" > /dev/null; then
    log "HTTPS 连接测试成功！服务器返回了成功的响应。"
    SUCCESS_LOG+=("$CURRENT_STAGE")
else
    error "HTTPS 连接测试失败。请检查 Nginx 配置、DNS解析和防火墙设置。"
fi

#-----------------------------
# 4. 收尾
#-----------------------------
print_summary
