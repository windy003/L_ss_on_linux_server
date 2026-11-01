#!/usr/bin/env bash
# =============================================================================
#  ss-install.sh —— Ubuntu / Debian 一键安装 Shadowsocks 服务端
#
#  运行后会自动生成一个 ss:// 开头的链接，复制到客户端
#  (Windows / macOS / Android / iOS / OpenWrt) 里导入即可使用。
#
#  快速开始（在服务器上以 root 执行）:
#      bash ss-install.sh
#
#  常用示例:
#      bash ss-install.sh -p 8443 -k MyPass123 -t Tokyo-01 --bbr
#      bash ss-install.sh --uninstall
#
#  完整参数见: bash ss-install.sh -h
# =============================================================================

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "请使用 bash 运行: sudo bash $0" >&2
  exit 1
fi

set -euo pipefail

# ---------------------------------------------------------------------------
# 日志输出
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_BLD=''; C_RST=''
fi
info() { printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
CONF_DIR="/etc/shadowsocks-libev"
CONF_FILE="$CONF_DIR/config.json"
META_FILE="$CONF_DIR/.ss-meta"
UNIT_NAME="ss-server.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
LINK_FILE="/root/ss-link.txt"
DEFAULT_METHOD="aes-256-gcm"

# ---------------------------------------------------------------------------
# 默认参数
# ---------------------------------------------------------------------------
SS_PORT=""
SS_PASSWORD=""
SS_METHOD=""
SS_HOST=""
SS_TAG=""
SS_BIN=""
FORCE=0
ENABLE_BBR=0
ACTION="install"
APT_READY=0

# ss:// 链接（在 build_links 中生成）
SS_LINK_SIP002=""
SS_LINK_LEGACY=""

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
ss-install.sh — Ubuntu / Debian 一键安装 Shadowsocks 服务端

用法:
  sudo bash ss-install.sh [选项]

选项:
  -p, --port <端口>        服务端口（默认: 随机 10000-65000）
  -k, --password <密码>    连接密码（默认: 随机 24 位字母数字）
  -m, --method <加密方式>  加密方式（默认: aes-256-gcm）
  -H, --host <地址>        链接中使用的服务器地址（默认: 自动探测公网 IP）
  -t, --tag <名称>         节点名称，即 ss:// 链接 # 后面的备注
      --bbr                启用 BBR 拥塞控制（推荐，通常能明显提速）
  -f, --force              忽略已有配置，强制重新生成端口和密码
  -u, --uninstall          卸载服务端
  -h, --help               显示本帮助

支持的加密方式（AEAD，客户端兼容性最好）:
  aes-256-gcm  aes-192-gcm  aes-128-gcm
  chacha20-ietf-poly1305    xchacha20-ietf-poly1305

示例:
  sudo bash ss-install.sh
  sudo bash ss-install.sh -p 8443 -k MyPass123 -t Tokyo-01 --bbr
  sudo bash ss-install.sh --uninstall
EOF
}

# ---------------------------------------------------------------------------
# 基础工具函数
# ---------------------------------------------------------------------------
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root 权限，请用: sudo bash $0"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

gen_password() {
  # 24 位随机字母数字；tr 被 head 打断时会产生 SIGPIPE，用 || true 吞掉
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true
}

port_in_use() {
  local p="$1"
  command -v ss >/dev/null 2>&1 || return 1
  [[ -n "$(ss -H -tuln "sport = :$p" 2>/dev/null)" ]]
}

pick_port() {
  local p i
  for i in $(seq 1 100); do
    p="$(shuf -i 10000-65000 -n 1)"
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

meta_get() {
  local key="$1"
  [[ -f "$META_FILE" ]] || return 0
  grep -m1 "^${key}=" "$META_FILE" 2>/dev/null | cut -d= -f2- || true
}

detect_host() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip https://ip.sb; do
    ip="$(curl -4 -fsS --connect-timeout 4 --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

build_links() {
  local tag userinfo
  tag="$SS_TAG"
  [[ -n "$tag" ]] || tag="SS-${SS_PORT}"
  tag="$(printf '%s' "$tag" | sed 's/[^A-Za-z0-9._-]/-/g')"
  [[ -n "$tag" ]] || tag="SS-${SS_PORT}"
  SS_TAG="$tag"

  # SIP002: ss://base64url(method:password)@host:port#tag
  userinfo="$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  SS_LINK_SIP002="ss://${userinfo}@${SS_HOST}:${SS_PORT}#${tag}"

  # 旧版: ss://base64(method:password@host:port)
  SS_LINK_LEGACY="ss://$(printf '%s:%s@%s:%s' \
    "$SS_METHOD" "$SS_PASSWORD" "$SS_HOST" "$SS_PORT" | base64 -w0)"
}

# ---------------------------------------------------------------------------
# APT 相关
# ---------------------------------------------------------------------------
apt_update_once() {
  [[ $APT_READY -eq 1 ]] && return 0
  export DEBIAN_FRONTEND=noninteractive
  info "更新软件包索引 ..."
  apt-get update -y -qq || warn "apt-get update 失败，继续尝试安装"
  APT_READY=1
}

apt_install() {
  apt_update_once
  apt-get install -y -qq "$@" || die "安装失败: $*"
}

# ---------------------------------------------------------------------------
# 安装服务端
# ---------------------------------------------------------------------------
install_shadowsocks_rust() {
  warn "软件源中没有 shadowsocks-libev，改用 shadowsocks-rust 官方静态版本。"
  apt_install curl ca-certificates xz-utils

  local arch target tag url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  target="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
    armv7l|armv7)  target="armv7-unknown-linux-musleabihf" ;;
    i386|i686)     target="i686-unknown-linux-musl" ;;
    *) die "不支持的 CPU 架构: $arch" ;;
  esac

  info "查询 shadowsocks-rust 最新版本 ..."
  tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null \
        | sed 's#.*/tag/##' || true)"
  [[ "$tag" =~ ^v[0-9] ]] || die "无法获取 shadowsocks-rust 版本号（网络问题？）"

  url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${tag}/shadowsocks-${tag}.${target}.tar.xz"
  tmp="$(mktemp -d)"
  info "下载 $url ..."
  if ! curl -fL --retry 3 --connect-timeout 10 -o "$tmp/ss.tar.xz" "$url"; then
    rm -rf "$tmp"
    die "下载失败，请检查服务器网络"
  fi
  tar -xJf "$tmp/ss.tar.xz" -C "$tmp" || { rm -rf "$tmp"; die "解压失败"; }
  install -m 0755 "$tmp/ssserver" /usr/local/bin/ssserver || { rm -rf "$tmp"; die "安装失败"; }
  rm -rf "$tmp"

  SS_BIN="/usr/local/bin/ssserver"
  ok "shadowsocks-rust 安装完成: $SS_BIN"
}

install_shadowsocks() {
  apt_update_once

  if ! apt-cache show shadowsocks-libev >/dev/null 2>&1; then
    info "APT 源中未找到 shadowsocks-libev，尝试启用 universe 源 ..."
    apt-get install -y -qq software-properties-common >/dev/null 2>&1 || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
      APT_READY=0
      apt_update_once
    fi
  fi

  if apt-cache show shadowsocks-libev >/dev/null 2>&1; then
    info "安装 shadowsocks-libev ..."
    apt_install shadowsocks-libev
    SS_BIN="$(command -v ss-server || true)"
    [[ -n "$SS_BIN" ]] || die "安装后未找到 ss-server"
    ok "shadowsocks-libev 安装完成: $SS_BIN"
    return 0
  fi

  install_shadowsocks_rust
}

# ---------------------------------------------------------------------------
# 写配置 / systemd 服务
# ---------------------------------------------------------------------------
write_config() {
  local pass_json pass_b64
  install -d -m 0755 "$CONF_DIR"

  pass_json="$(json_escape "$SS_PASSWORD")"
  cat > "$CONF_FILE" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${SS_PORT},
    "password": "${pass_json}",
    "method": "${SS_METHOD}",
    "timeout": 300,
    "mode": "tcp_and_udp",
    "fast_open": false
}
EOF

  # 配置里有密码，只允许 root 和 nogroup 组读取（服务以 nobody:nogroup 运行）
  if getent group nogroup >/dev/null 2>&1; then
    chown root:nogroup "$CONF_FILE" 2>/dev/null || true
    chmod 640 "$CONF_FILE"
  else
    chmod 644 "$CONF_FILE"
  fi

  pass_b64="$(printf '%s' "$SS_PASSWORD" | base64 -w0)"
  cat > "$META_FILE" <<EOF
META_PORT=${SS_PORT}
META_PASS_B64=${pass_b64}
META_METHOD=${SS_METHOD}
EOF
  chmod 600 "$META_FILE"
}

write_service() {
  local group_line=""
  getent group nogroup >/dev/null 2>&1 && group_line="Group=nogroup"

  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Shadowsocks Server
Documentation=https://shadowsocks.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
${group_line}
LimitNOFILE=51200
ExecStart=${SS_BIN} -c ${CONF_FILE}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT_FILE"
}

disable_packaged_services() {
  local u
  for u in shadowsocks-libev.service shadowsocks-libev-server@.service; do
    if systemctl list-unit-files --no-legend "$u" 2>/dev/null | grep -q .; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
    fi
  done
}

start_service() {
  disable_packaged_services
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || true
  systemctl restart "$UNIT_NAME" >/dev/null 2>&1 || true
  sleep 1

  if ! systemctl is-active --quiet "$UNIT_NAME"; then
    warn "服务启动失败，最近的日志如下："
    journalctl -u "$UNIT_NAME" -n 40 --no-pager 2>/dev/null || true
    die "请根据上面的日志排查问题"
  fi
  ok "服务已启动: $UNIT_NAME"
}

# ---------------------------------------------------------------------------
# 防火墙 / BBR
# ---------------------------------------------------------------------------
open_firewall() {
  local changed=0

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "${SS_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${SS_PORT}/udp" >/dev/null 2>&1 || true
    changed=1
    ok "已在 ufw 中放行 TCP/UDP ${SS_PORT}"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${SS_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${SS_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    changed=1
    ok "已在 firewalld 中放行 TCP/UDP ${SS_PORT}"
  fi

  if [[ $changed -eq 0 ]]; then
    info "未检测到启用的 ufw/firewalld，跳过本机防火墙配置"
  fi
}

enable_bbr() {
  local cur
  cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')"
  if [[ "$cur" == "bbr" ]]; then
    ok "BBR 已经处于启用状态"
    return 0
  fi

  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-bbr-ss.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true

  cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')"
  if [[ "$cur" == "bbr" ]]; then
    ok "BBR 已启用"
  else
    warn "BBR 启用失败（内核可能不支持，当前: ${cur:-unknown}）"
  fi
}

# ---------------------------------------------------------------------------
# 输出结果
# ---------------------------------------------------------------------------
print_result() {
  local content
  content="$(cat <<EOF
${C_BLD}============================================================${C_RST}
${C_GRN}  Shadowsocks 安装完成${C_RST}
${C_BLD}============================================================${C_RST}
 服务器地址 : ${SS_HOST}
 端口       : ${SS_PORT}
 密码       : ${SS_PASSWORD}
 加密方式   : ${SS_METHOD}
 节点名称   : ${SS_TAG}
 服务状态   : $(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo unknown)  (${UNIT_NAME})
------------------------------------------------------------
 ${C_CYN}把下面这个 ss:// 链接复制到客户端导入即可使用：${C_RST}
${C_GRN}${SS_LINK_SIP002}${C_RST}
------------------------------------------------------------
 兼容旧版客户端（老版本 Windows / SSR 客户端）：
${SS_LINK_LEGACY}
------------------------------------------------------------
 链接已保存到: ${LINK_FILE}
 提示: 若客户端连不上，请确认云服务商安全组已放行
       TCP 和 UDP 端口 ${SS_PORT}（SS 的 UDP 转发需要放行 UDP）
${C_BLD}============================================================${C_RST}
EOF
)"
  printf '%s\n' "$content"
  printf '%s\n' "$content" > "$LINK_FILE"
  chmod 600 "$LINK_FILE"
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
do_uninstall() {
  info "停止并移除 ${UNIT_NAME} ..."
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -f "$CONF_FILE" "$META_FILE" "$LINK_FILE"
  rmdir "$CONF_DIR" 2>/dev/null || true

  if dpkg -s shadowsocks-libev >/dev/null 2>&1; then
    info "卸载 shadowsocks-libev 软件包 ..."
    apt-get purge -y -qq shadowsocks-libev >/dev/null 2>&1 || true
  fi
  rm -f /usr/local/bin/ssserver

  ok "卸载完成"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--port)
        [[ $# -ge 2 ]] || die "参数 $1 缺少取值"
        SS_PORT="$2"; shift 2 ;;
      --port=*)      SS_PORT="${1#*=}"; shift ;;
      -k|--password)
        [[ $# -ge 2 ]] || die "参数 $1 缺少取值"
        SS_PASSWORD="$2"; shift 2 ;;
      --password=*)  SS_PASSWORD="${1#*=}"; shift ;;
      -m|--method)
        [[ $# -ge 2 ]] || die "参数 $1 缺少取值"
        SS_METHOD="$2"; shift 2 ;;
      --method=*)    SS_METHOD="${1#*=}"; shift ;;
      -H|--host)
        [[ $# -ge 2 ]] || die "参数 $1 缺少取值"
        SS_HOST="$2"; shift 2 ;;
      --host=*)      SS_HOST="${1#*=}"; shift ;;
      -t|--tag)
        [[ $# -ge 2 ]] || die "参数 $1 缺少取值"
        SS_TAG="$2"; shift 2 ;;
      --tag=*)       SS_TAG="${1#*=}"; shift ;;
      --bbr)         ENABLE_BBR=1; shift ;;
      -f|--force)    FORCE=1; shift ;;
      -u|--uninstall) ACTION="uninstall"; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "未知参数: $1（使用 -h 查看帮助）" ;;
    esac
  done

  if [[ -n "$SS_PORT" ]]; then
    [[ "$SS_PORT" =~ ^[0-9]+$ ]] || die "端口必须是数字: $SS_PORT"
    (( SS_PORT >= 1 && SS_PORT <= 65535 )) || die "端口范围必须在 1-65535: $SS_PORT"
  fi

  if [[ -n "$SS_METHOD" ]]; then
    SS_METHOD="${SS_METHOD,,}"
  fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  if [[ "$ACTION" == "uninstall" ]]; then
    require_root
    do_uninstall
    exit 0
  fi

  require_root
  command -v systemctl >/dev/null 2>&1 || die "本脚本依赖 systemd，当前系统没有 systemctl"
  command -v apt-get   >/dev/null 2>&1 || die "本脚本仅支持 Debian / Ubuntu"

  apt_update_once
  apt_install curl ca-certificates
  command -v ss >/dev/null 2>&1 || apt-get install -y -qq iproute2 >/dev/null 2>&1 || true

  # ---- 读取上次的配置（便于重复运行时保持一致）----
  local old_port="" old_pass="" old_method="" pass_b64=""
  if [[ "$FORCE" -eq 0 && -f "$META_FILE" ]]; then
    old_port="$(meta_get META_PORT)"
    old_method="$(meta_get META_METHOD)"
    pass_b64="$(meta_get META_PASS_B64)"
    if [[ -n "$pass_b64" ]]; then
      old_pass="$(printf '%s' "$pass_b64" | base64 -d 2>/dev/null || true)"
    fi
  fi

  # ---- 确定端口 / 密码 / 加密方式 ----
  if [[ -z "$SS_PORT" && -n "$old_port" ]]; then SS_PORT="$old_port"; fi
  if [[ -z "$SS_PASSWORD" && -n "$old_pass" ]]; then SS_PASSWORD="$old_pass"; fi
  if [[ -z "$SS_METHOD" && -n "$old_method" ]]; then SS_METHOD="$old_method"; fi

  if [[ -z "$SS_PORT" ]]; then
    SS_PORT="$(pick_port)" || die "无法找到空闲端口，请用 -p 手动指定"
  fi
  if [[ -z "$SS_PASSWORD" ]]; then
    SS_PASSWORD="$(gen_password)"
  fi
  [[ -n "$SS_PASSWORD" ]] || die "密码生成失败，请用 -k 手动指定"
  [[ "$SS_PASSWORD" != *$'\n'* ]] || die "密码不能包含换行符"

  SS_METHOD="${SS_METHOD:-$DEFAULT_METHOD}"
  case "$SS_METHOD" in
    aes-256-gcm|aes-192-gcm|aes-128-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|chacha20-poly1305) ;;
    *) warn "加密方式 ${SS_METHOD} 不是常见的 AEAD 算法，请确认客户端支持" ;;
  esac

  # ---- 服务器地址 ----
  if [[ -n "$SS_HOST" ]]; then
    info "使用指定的服务器地址: $SS_HOST"
  else
    SS_HOST="$(detect_host)" || true
    if [[ -z "$SS_HOST" ]]; then
      SS_HOST="YOUR_SERVER_IP"
      warn "自动探测公网 IP 失败，请把链接里的 YOUR_SERVER_IP 换成真实地址（或用 -H 指定）"
    else
      info "探测到公网 IP: $SS_HOST"
    fi
  fi
  if [[ "$SS_HOST" =~ ^(10\.|192\.168\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
    warn "检测到内网地址，如果服务器在 NAT 后面，请用 -H 指定公网 IP 或域名"
  fi
  # IPv6 字面量需要加方括号
  if [[ "$SS_HOST" == *:* && "$SS_HOST" != \[* ]]; then
    SS_HOST="[$SS_HOST]"
  fi

  # ---- 安装 ----
  install_shadowsocks

  # ---- 写配置并启动 ----
  write_config
  write_service
  start_service

  # ---- 系统优化 / 防火墙 ----
  if [[ $ENABLE_BBR -eq 1 ]]; then
    enable_bbr
  fi
  open_firewall

  # ---- 生成链接并输出 ----
  build_links
  print_result

  echo
  info "查看服务状态: systemctl status $UNIT_NAME"
  info "查看运行日志: journalctl -u $UNIT_NAME -f"
}

main "$@"
