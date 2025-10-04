#!/bin/bash

# --- 颜色定义 ---
BLUE='\033[1;36m'
NC='\033[0m' # 无颜色

# 检查是否提供了域名作为参数
if [ -z "$1" ]; then
  echo -e "${BLUE}用法: $0 your_domain${NC}"
  exit 1
fi

DOMAIN=$1
WEB_ROOT="/var/www/$DOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
PHP_VERSION="php8.4" # 根据系统安装的PHP版本进行调整

echo -e "${BLUE}==========================================================${NC}"
echo -e "${BLUE}  开始为域名申请SSL证书: $DOMAIN   ${NC}"
echo -e "${BLUE}==========================================================${NC}"

# 创建网站的根目录
echo -e "\n${BLUE}[信息] 正在创建网站根目录: $WEB_ROOT...${NC}"
mkdir -p $WEB_ROOT
echo -e "${BLUE}[成功] 网站根目录已创建。${NC}"

# 初始配置Nginx虚拟主机以处理HTTP请求，为certbot证书申请做准备
echo -e "\n${BLUE}[信息] 正在为HTTP挑战创建临时Nginx配置...${NC}"
cat > $NGINX_CONF <<- 'EOM'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    root WEB_ROOT_PLACEHOLDER;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOM

# 替换占位符
sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" $NGINX_CONF
sed -i "s|WEB_ROOT_PLACEHOLDER|$WEB_ROOT|g" $NGINX_CONF
echo -e "${BLUE}[成功] 临时Nginx配置已创建于 $NGINX_CONF。${NC}"

# 创建符号链接，启用Nginx虚拟主机配置
echo -e "\n${BLUE}[信息] 正在启用Nginx站点...${NC}"
ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
echo -e "${BLUE}[成功] 站点已启用。${NC}"

# 重新加载Nginx，应用配置变更
echo -e "\n${BLUE}[信息] 正在重载Nginx以应用临时配置...${NC}"
systemctl reload nginx
echo -e "${BLUE}[成功] Nginx已重载。${NC}"

# 使用certbot自动申请Let's Encrypt SSL证书
echo -e "\n${BLUE}[信息] 正在使用Certbot请求Let's Encrypt SSL证书...${NC}"
certbot certonly --webroot -w $WEB_ROOT -d $DOMAIN --agree-tos --email root@omnios.world --non-interactive
echo -e "${BLUE}[成功] Certbot处理完成。${NC}"

# 删除原始的HTTP服务器配置
echo -e "\n${BLUE}[信息] 正在移除临时Nginx配置...${NC}"
rm $NGINX_CONF
echo -e "${BLUE}[成功] 临时配置已移除。${NC}"

# 配置Nginx虚拟主机以处理HTTP和HTTPS请求
echo -e "\n${BLUE}[信息] 正在创建最终的HTTPS Nginx配置...${NC}"
cat > $NGINX_CONF <<- EOM
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri; # 将所有HTTP请求重定向到HTTPS
}

server {
    listen 443 ssl;
    server_name $DOMAIN;
    root $WEB_ROOT; # 指定网站根目录
    client_max_body_size 8000M; # 设置客户端请求体的最大大小
    index index.php index.html;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem; # 指定SSL证书
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem; # 指定SSL证书密钥

    access_log /var/log/nginx/$DOMAIN-access.log; # 配置访问日志
    error_log /var/log/nginx/$DOMAIN-error.log; # 配置错误日志

    # 强制浏览器使用HTTPS连接，提高安全性
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location ~ \.php(?:\$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include snippets/fastcgi-php.conf;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_param HTTPS on;
        fastcgi_pass unix:/var/run/php/$PHP_VERSION-fpm.sock;
    }
}
EOM
echo -e "${BLUE}[成功] 最终Nginx配置已创建。${NC}"

# 重新加载Nginx，应用配置变更
echo -e "\n${BLUE}[信息] 正在重载Nginx以应用最终HTTPS配置...${NC}"
systemctl reload nginx
echo -e "${BLUE}[成功] Nginx已重载。${NC}"

# 检查HTTPS连接是否正常
echo -e "\n${BLUE}[信息] 暂停5秒后进行验证...${NC}"
sleep 5
echo -e "\n${BLUE}[信息] 正在验证HTTPS连接: https://$DOMAIN...${NC}"
curl --head https://$DOMAIN

echo -e "\n${BLUE}==========================================================${NC}"
echo -e "${BLUE}  脚本执行完毕。请检查以上输出信息。                ${NC}"
echo -e "${BLUE}==========================================================${NC}"
