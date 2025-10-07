#!/usr/bin/env bash
# MongoDB Community 8.2 on Debian 12/13
# - Debian 12: 使用官方 bookworm/8.2 仓库
# - Debian 13: 暂时复用 bookworm/8.2 仓库（官方文档尚未列出 trixie）
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行"; exit 1
fi

source /etc/os-release || { echo "无法读取 /etc/os-release"; exit 1; }
CODENAME="${VERSION_CODENAME:-}"
case "$CODENAME" in
  bookworm) REPO_DIST="bookworm" ;;
  trixie)   REPO_DIST="bookworm"; echo "提示: Debian 13(trixie) 目前使用 bookworm 仓库以获取 8.2 包。" ;;
  *) echo "不支持的 Debian 版本: $CODENAME"; exit 1 ;;
esac

MONGO_SERIES="8.2"
KEYRING="/usr/share/keyrings/mongodb-server-8.0.gpg"   # 8.x 签名密钥
LIST="/etc/apt/sources.list.d/mongodb-org-${MONGO_SERIES}.list"

apt-get update
apt-get install -y curl gnupg ca-certificates lsb-release

# 导入 MongoDB 8.x 公钥（官方文档示例使用 8.0 密钥文件名）
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
  | gpg --dearmor > "${KEYRING}"

# 写入 8.2 系列 APT 源
echo "deb [signed-by=${KEYRING}] http://repo.mongodb.org/apt/debian ${REPO_DIST}/mongodb-org/${MONGO_SERIES} main" \
  > "${LIST}"

apt-get update

# 避免与 Debian 社区版 mongodb 包冲突（若存在）
if dpkg -l | awk '{print $2}' | grep -qx "mongodb"; then
  apt-get remove -y mongodb
fi

# 安装服务器与工具
apt-get install -y mongodb-org

# 固定当前 8.2.x 版本，防止无意升级到其他大版本
for pkg in mongodb-org mongodb-org-database mongodb-org-server mongodb-org-mongos mongodb-org-tools mongodb-mongosh mongodb-org-database-tools-extra; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-mark hold "$pkg" || true
  fi
done

# 启用并启动
systemctl daemon-reload || true
systemctl enable --now mongod

# 简要验收
sleep 2
systemctl --no-pager --full status mongod | sed -n '1,10p' || true
mongod --version | head -n1 || true
mongosh --version || true
echo "完成。"
