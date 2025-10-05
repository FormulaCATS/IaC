#!/usr/bin/env bash
# Debian 13 (trixie) · Non-interactive PGDG setup + PostgreSQL 17 install + status checks
# - Zero prompts, zero "press any key"
# - Key outputs in sky-blue
# - Clean, idempotent, and exit-on-error

set -Eeuo pipefail

############################
# Styling
############################
# Choose a readable "sky blue" for most terminals; prefer 256-color if available.
if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
  CYAN=$'\033[38;5;117m'
else
  CYAN=$'\033[36m'
fi
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

hr() { printf '%s\n' "${DIM}────────────────────────────────────────────────────${RESET}"; }
sec() { hr; printf '%s\n' "${BOLD}$*${RESET}"; hr; }
out() { printf '%s%s%s\n' "${CYAN}" "$*" "${RESET}"; }
ok()  { printf '%s✓ %s%s\n' "${BOLD}" "$*" "${RESET}"; }
err() { printf '%s✗ %s%s\n' "${BOLD}" "$*" "${RESET}" >&2; }

############################
# Privilege model
############################
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

############################
# Non-interactive APT
############################
export DEBIAN_FRONTEND=noninteractive
APT_INSTALL_OPTS=(
  -y
  -o Dpkg::Options::=--force-confnew
  -o Dpkg::Use-Pty=0
)

on_err() {
  err "命令失败 · 行号: $1"
  exit 1
}
trap 'on_err $LINENO' ERR

############################
# 0) Detect codename and arch
############################
sec "环境检测"
CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
ARCH="$(dpkg --print-architecture)"
if [ -z "${CODENAME}" ]; then
  err "无法识别 Debian 代号（/etc/os-release 缺失 VERSION_CODENAME）"
  exit 2
fi
out "Debian 代号: ${CODENAME}"
out "CPU 架构: ${ARCH}"

############################
# 1) 准备 PGDG 仓库（非交互）
############################
sec "准备 PGDG 仓库（官方源，非交互）"
${SUDO} apt-get update -y >/dev/null
${SUDO} apt-get install "${APT_INSTALL_OPTS[@]}" --no-install-recommends \
  ca-certificates curl gnupg lsb-release >/dev/null

# Keyring
${SUDO} install -d -m 0755 /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/postgresql.gpg ]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  ok "导入 PGDG 签名密钥"
else
  ok "PGDG 签名密钥已存在，跳过导入"
fi

# Source list
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
PGDG_LINE="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main"
if [ ! -f "${PGDG_LIST}" ] || ! grep -Fq "${CODENAME}-pgdg main" "${PGDG_LIST}"; then
  echo "${PGDG_LINE}" | ${SUDO} tee "${PGDG_LIST}" >/dev/null
  ok "写入 PGDG 源: ${CODENAME}-pgdg"
else
  ok "PGDG 源已存在，跳过写入"
fi

${SUDO} apt-get update -y >/dev/null
ok "apt 索引更新完毕"

############################
# 2) 安装 PostgreSQL 17（非交互）
############################
sec "安装 PostgreSQL 17 与客户端"
${SUDO} apt-get install "${APT_INSTALL_OPTS[@]}" \
  postgresql-common postgresql-17 postgresql-client-17 >/dev/null
ok "软件包安装完成"

# 确保服务已启动
${SUDO} systemctl enable --now postgresql >/dev/null 2>&1 || true
STATE="$(${SUDO} systemctl is-active postgresql 2>/dev/null || true)"
out "postgresql 服务状态: ${STATE:-unknown}"

############################
# 3) 基本验证（无阻塞）
############################
sec "基本验证"
# psql 版本
if command -v psql >/dev/null 2>&1; then
  out "psql 版本: $(psql --version)"
else
  err "未找到 psql 可执行文件"
fi

# SQL 版本信息
if getent passwd postgres >/dev/null 2>&1; then
  SQL_VER="$(${SUDO} -u postgres psql -Atqc "SELECT version();" 2>/dev/null || true)"
  if [ -n "${SQL_VER}" ]; then
    out "数据库内核: ${SQL_VER}"
  else
    err "无法获取数据库内核版本（可能服务未就绪）"
  fi
else
  err "系统用户 postgres 不存在"
fi

# 集群列表（端口、状态、数据目录）
if command -v pg_lsclusters >/dev/null 2>&1; then
  out "集群列表:"
  # 彩色逐行输出
  while IFS= read -r line; do
    printf '%s%s%s\n' "${CYAN}" "${line}" "${RESET}"
  done < <(pg_lsclusters 2>/dev/null || true)
else
  err "未找到 pg_lsclusters"
fi

############################
# 4) 退出状态与简报
############################
sec "结果小结"
HAS_17="$(psql -Atqc "SHOW server_version;" 2>/dev/null | cut -d. -f1 || true)"
if [ "${HAS_17:-}" = "17" ]; then
  ok "PostgreSQL 17 安装并可用"
else
  err "PostgreSQL 17 可能未成功启动或运行"
fi

out "脚本执行完成（全程非交互，无人为按键）。"
