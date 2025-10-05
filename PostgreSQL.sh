#!/usr/bin/env bash
# Debian 13 (trixie) · PGDG + PostgreSQL 17 · 无交互安装与非阻塞状态检测（幂等）

set -Eeuo pipefail

# ---------- 样式 ----------
if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
  CYAN=$'\033[38;5;117m'
else
  CYAN=$'\033[36m'
fi
BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
hr(){ printf '%s\n' "${DIM}────────────────────────────────────────────────────${RESET}"; }
sec(){ hr; printf '%s\n' "${BOLD}$*${RESET}"; hr; }
out(){ printf '%s%s%s\n' "${CYAN}" "$*" "${RESET}"; }
ok(){  printf '%s✓ %s%s\n' "${BOLD}" "$*" "${RESET}"; }
err(){ printf '%s✗ %s%s\n' "${BOLD}" "$*" "${RESET}" >&2; }

# ---------- 提权/APT ----------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive
APT_INSTALL_OPTS=(-y -o Dpkg::Options::=--force-confnew -o Dpkg::Use-Pty=0)
trap 'err "命令失败 · 行号: $LINENO"; exit 1' ERR

# ---------- 环境检测 ----------
sec "环境检测"
CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
ARCH="$(dpkg --print-architecture)"
[ -n "${CODENAME}" ] || { err "无法识别 Debian 代号"; exit 2; }
out "Debian 代号: ${CODENAME}"
out "CPU 架构: ${ARCH}"

# ---------- PGDG 仓库 ----------
sec "准备 PGDG 仓库（官方源，非交互）"
${SUDO} apt-get update -y >/dev/null
${SUDO} apt-get install "${APT_INSTALL_OPTS[@]}" --no-install-recommends ca-certificates curl gnupg lsb-release >/dev/null

${SUDO} install -d -m 0755 /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/postgresql.gpg ]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/postgresql.gpg
  ok "导入 PGDG 签名密钥"
else
  ok "PGDG 签名密钥已存在，跳过导入"
fi

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

# ---------- 安装 PostgreSQL 17 ----------
sec "安装 PostgreSQL 17 与客户端"
${SUDO} apt-get install "${APT_INSTALL_OPTS[@]}" postgresql-common postgresql-17 postgresql-client-17 >/dev/null
ok "软件包安装完成"

${SUDO} systemctl enable --now postgresql >/dev/null 2>&1 || true
STATE="$(${SUDO} systemctl is-active postgresql 2>/dev/null || true)"
out "postgresql 服务状态: ${STATE:-unknown}"

# ---------- 以 postgres 身份执行 的统一封装 ----------
# 在 root 下优先使用 runuser；非 root 使用 sudo。均注入最小 PATH 和干净环境。
MIN_PATH="/usr/lib/postgresql/17/bin:/usr/bin:/bin"
if [ "$(id -u)" -eq 0 ]; then
  PG_EXEC=(runuser -u postgres --)
else
  PG_EXEC=(sudo -u postgres)
fi
pgexec() { "${PG_EXEC[@]}" env -i PATH="${MIN_PATH}" PSQL_PAGER= "$@"; }
pgexec_to() { # pgexec 带超时（秒）
  local sec="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${sec}s" "${PG_EXEC[@]}" env -i PATH="${MIN_PATH}" PSQL_PAGER= "$@"
  else
    "${PG_EXEC[@]}" env -i PATH="${MIN_PATH}" PSQL_PAGER= "$@"
  fi
}

# ---------- 探测端口 ----------
PGPORT="$(
  command -v pg_lsclusters >/dev/null 2>&1 \
    && pg_lsclusters --no-header 2>/dev/null | awk '$4=="online"{print $3; exit}' \
    || echo 5432
)"

# ---------- 基本验证（非阻塞） ----------
sec "基本验证"
if command -v psql >/dev/null 2>&1; then
  out "psql 版本: $(psql --version)"
else
  err "未找到 psql 可执行文件"
fi

# 1) 就绪检查：先 UNIX socket，失败回退 127.0.0.1；每步 2 秒超时
READY_OUT="$(pgexec_to 2 pg_isready -h /var/run/postgresql -p "${PGPORT}" -t 2 2>&1 || true)"
if ! printf '%s' "${READY_OUT}" | grep -qi 'accepting connections'; then
  READY_FB="$(pgexec_to 2 pg_isready -h 127.0.0.1 -p "${PGPORT}" -t 2 2>&1 || true)"
  [ -n "${READY_FB}" ] && READY_OUT="${READY_OUT}${READY_OUT:+ ; }${READY_FB}"
fi
[ -n "${READY_OUT}" ] && out "pg_isready: ${READY_OUT}" || err "pg_isready 未产生输出"

# 2) SQL 版本：以 postgres 身份，通过 UNIX socket，2 秒超时
SQL_VER="$(pgexec_to 2 psql -h /var/run/postgresql -p "${PGPORT}" -d postgres -Atqc 'SELECT version();' 2>/dev/null || true)"
if [ -n "${SQL_VER}" ]; then
  out "数据库内核: ${SQL_VER}"
else
  err "无法读取数据库内核版本（已限定 2 秒超时）"
fi

# 3) 集群列表
if command -v pg_lsclusters >/dev/null 2>&1; then
  out "集群列表:"
  while IFS= read -r line; do printf '%s%s%s\n' "${CYAN}" "${line}" "${RESET}"; done < <(pg_lsclusters 2>/dev/null || true)
else
  err "未找到 pg_lsclusters"
fi

# ---------- 结果小结 ----------
sec "结果小结"
OK_SERVICE="$([ "${STATE}" = "active" ] && echo yes || echo no)"
OK_READY="$(printf '%s' "${READY_OUT}" | grep -qi 'accepting connections' && echo yes || echo no)"
OK_SQL="$([ -n "${SQL_VER}" ] && echo yes || echo no)"
if [ "${OK_SERVICE}" = yes ] && { [ "${OK_READY}" = yes ] || [ "${OK_SQL}" = yes ]; }; then
  ok "PostgreSQL 17 运行正常（端口 ${PGPORT}）"
else
  err "PostgreSQL 可能未完全就绪：service=${OK_SERVICE}, ready=${OK_READY}, sql=${OK_SQL}"
fi
out "脚本执行完成（全程非交互，检测均设短超时，无阻塞）。"
