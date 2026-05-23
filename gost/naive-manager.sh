#!/usr/bin/env bash
set -euo pipefail

# naive-front 独立模式管理脚本（kaifa-2026-05-25 起）
# 不再依赖 sing-box；naive-front 自带 TCP（HTTP/1.1+HTTP/2）+ QUIC（HTTP/3）双入站
# 与 direct/socks5/http 三种出站。

BASE_DIR="/root/docker-compose/naive-front"
NAIVE_BIN="$BASE_DIR/naive-front"
STATE_FILE="$BASE_DIR/manager-state.env"
REVERSE_PROXY_FILE="$BASE_DIR/reverse-proxies.tsv"
NAIVE_CONFIG="$BASE_DIR/naive-front.json"
NAIVE_SERVICE="naive-front.service"
NAIVE_RELEASE_REPO="jiajiacundai/myhy"
NAIVE_RELEASE_TAG="naive-front-latest"
NAIVE_ASSET_PREFIX="naive-front-linux"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err() { printf "${RED}[ERR]${NC} %s\n" "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 运行此脚本"
    exit 1
  fi
}

pause() { read -r -p "按回车继续..." _ || true; }

confirm_default_yes() {
  local prompt="$1" answer
  read -r -p "$(printf "${CYAN}%s [Y/n]: ${NC}" "$prompt")" answer || true
  case "${answer,,}" in n|no) return 1 ;; *) return 0 ;; esac
}

confirm_default_no() {
  local prompt="$1" answer
  read -r -p "$(printf "${CYAN}%s [y/N]: ${NC}" "$prompt")" answer || true
  case "${answer,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

prompt_value() {
  local prompt="$1" default_value="${2:-}" required="${3:-false}" value
  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "$(printf "${CYAN}%s [%s]: ${NC}" "$prompt" "$default_value")" value || true
      value="${value:-$default_value}"
    else
      read -r -p "$(printf "${CYAN}%s: ${NC}" "$prompt")" value || true
    fi
    if [[ "$required" == "true" && -z "$value" ]]; then
      warn "该项不可为空"
      continue
    fi
    printf '%s' "$value"
    return 0
  done
}

random_string() {
  local len="${1:-16}" value=""
  while [[ "${#value}" -lt "$len" ]]; do
    value+="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" || true)"
  done
  printf '%s' "${value:0:$len}"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() { printf '"%s"' "$(json_escape "$1")"; }

load_state() {
  NAIVE_USERNAME=""
  NAIVE_PASSWORD=""
  NAIVE_DOMAIN=""
  MASQUERADE_URL=""
  CERT_FILE=""
  KEY_FILE=""
  ENABLE_TCP="true"
  ENABLE_QUIC="true"
  OUTBOUND_TYPE="direct"
  SOCKS5_SERVER=""
  SOCKS5_PORT="1080"
  SOCKS5_USERNAME=""
  SOCKS5_PASSWORD=""

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state() {
  mkdir -p "$BASE_DIR"
  cat >"$STATE_FILE" <<EOF_STATE
NAIVE_USERNAME=$(printf '%q' "$NAIVE_USERNAME")
NAIVE_PASSWORD=$(printf '%q' "$NAIVE_PASSWORD")
NAIVE_DOMAIN=$(printf '%q' "$NAIVE_DOMAIN")
MASQUERADE_URL=$(printf '%q' "$MASQUERADE_URL")
CERT_FILE=$(printf '%q' "$CERT_FILE")
KEY_FILE=$(printf '%q' "$KEY_FILE")
ENABLE_TCP=$(printf '%q' "$ENABLE_TCP")
ENABLE_QUIC=$(printf '%q' "$ENABLE_QUIC")
OUTBOUND_TYPE=$(printf '%q' "$OUTBOUND_TYPE")
SOCKS5_SERVER=$(printf '%q' "$SOCKS5_SERVER")
SOCKS5_PORT=$(printf '%q' "$SOCKS5_PORT")
SOCKS5_USERNAME=$(printf '%q' "$SOCKS5_USERNAME")
SOCKS5_PASSWORD=$(printf '%q' "$SOCKS5_PASSWORD")
EOF_STATE
  chmod 600 "$STATE_FILE"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

download_file() {
  local url="$1" output="$2"
  if need_cmd curl; then
    curl -fsSL -o "$output" "$url"
  elif need_cmd wget; then
    wget -q -O "$output" "$url"
  else
    err "需要 curl 或 wget"; exit 1
  fi
}

install_naive_binary() {
  local arch asset url
  arch="$(detect_arch)"
  asset="${NAIVE_ASSET_PREFIX}-${arch}"
  url="https://github.com/${NAIVE_RELEASE_REPO}/releases/download/${NAIVE_RELEASE_TAG}/${asset}"
  info "下载 naive-front: $url"
  download_file "$url" "$NAIVE_BIN"
  chmod +x "$NAIVE_BIN"
  setcap cap_net_bind_service=+ep "$NAIVE_BIN" 2>/dev/null || true
  ok "naive-front 已安装: $NAIVE_BIN"
}

collect_node_config() {
  load_state
  local generated

  generated="$(random_string 12)"
  NAIVE_USERNAME="$(prompt_value "naive username（回车随机生成）" "${NAIVE_USERNAME:-$generated}" false)"

  generated="$(random_string 18)"
  NAIVE_PASSWORD="$(prompt_value "naive password（回车随机生成）" "${NAIVE_PASSWORD:-$generated}" false)"

  NAIVE_DOMAIN="$(prompt_value "naive 域名" "$NAIVE_DOMAIN" true)"
  MASQUERADE_URL="$(prompt_value "伪装网站 URL" "${MASQUERADE_URL:-https://global.toyota}" false)"

  printf "${CYAN}入站协议（建议两个都开）${NC}\n"
  if confirm_default_yes "启用 TCP 入站（HTTP/1.1 + HTTP/2 over TLS, 443/tcp）"; then
    ENABLE_TCP="true"
  else
    ENABLE_TCP="false"
  fi
  if confirm_default_yes "启用 QUIC 入站（HTTP/3, 443/udp）"; then
    ENABLE_QUIC="true"
  else
    ENABLE_QUIC="false"
  fi
  if [[ "$ENABLE_TCP" == "false" && "$ENABLE_QUIC" == "false" ]]; then
    warn "至少要保留一个入站，重置为两者都开"
    ENABLE_TCP="true"; ENABLE_QUIC="true"
  fi

  printf "${CYAN}出站类型${NC}\n"
  echo "1) direct  — 直接拨号到目标（默认，最简单）"
  echo "2) socks5  — 经 SOCKS5 代理出站"
  echo "3) http    — 经 HTTP CONNECT 代理出站"
  local outbound_choice
  outbound_choice="$(prompt_value "请选择 1/2/3" "1" false)"
  case "$outbound_choice" in
    2) OUTBOUND_TYPE="socks5" ;;
    3) OUTBOUND_TYPE="http" ;;
    *) OUTBOUND_TYPE="direct" ;;
  esac
  if [[ "$OUTBOUND_TYPE" == "socks5" || "$OUTBOUND_TYPE" == "http" ]]; then
    SOCKS5_SERVER="$(prompt_value "出站代理 IP/域名" "$SOCKS5_SERVER" true)"
    SOCKS5_PORT="$(prompt_value "出站代理端口" "${SOCKS5_PORT:-1080}" false)"
    SOCKS5_USERNAME="$(prompt_value "出站代理 username（可为空）" "$SOCKS5_USERNAME" false)"
    SOCKS5_PASSWORD="$(prompt_value "出站代理 password（可为空）" "$SOCKS5_PASSWORD" false)"
  else
    SOCKS5_SERVER=""; SOCKS5_PORT="1080"; SOCKS5_USERNAME=""; SOCKS5_PASSWORD=""
  fi

  CERT_FILE="$(prompt_value "TLS 证书文件" "${CERT_FILE:-/root/cert/cert.crt}" true)"
  KEY_FILE="$(prompt_value "TLS 私钥文件" "${KEY_FILE:-/root/cert/private.key}" true)"
  save_state
}

write_naive_config() {
  {
    cat <<EOF_JSON
{
  "listens": [
    "0.0.0.0:443",
    "[::]:443"
  ],
  "users": [
    {
      "username": $(json_string "$NAIVE_USERNAME"),
      "password": $(json_string "$NAIVE_PASSWORD")
    }
  ],
  "tls": {
    "cert_file": $(json_string "$CERT_FILE"),
    "key_file": $(json_string "$KEY_FILE"),
    "min_version": "1.2",
    "curve_preferences": ["x25519", "p256", "p384"],
    "session_tickets_disabled": false
  },
  "inbound": {
    "tcp": {
      "disabled": $([[ "$ENABLE_TCP" == "true" ]] && printf 'false' || printf 'true'),
      "http2": {}
    },
    "quic": {
      "disabled": $([[ "$ENABLE_QUIC" == "true" ]] && printf 'false' || printf 'true')
    }
  },
  "outbound": {
EOF_JSON

    case "$OUTBOUND_TYPE" in
      direct)
        printf '    "type": "direct"\n'
        ;;
      socks5)
        cat <<EOF_JSON
    "type": "socks5",
    "address": $(json_string "${SOCKS5_SERVER}:${SOCKS5_PORT}")$([[ -n "$SOCKS5_USERNAME" ]] && printf ',\n    "username": %s' "$(json_string "$SOCKS5_USERNAME")")$([[ -n "$SOCKS5_PASSWORD" ]] && printf ',\n    "password": %s' "$(json_string "$SOCKS5_PASSWORD")")
EOF_JSON
        ;;
      http)
        cat <<EOF_JSON
    "type": "http",
    "address": $(json_string "${SOCKS5_SERVER}:${SOCKS5_PORT}")$([[ -n "$SOCKS5_USERNAME" ]] && printf ',\n    "username": %s' "$(json_string "$SOCKS5_USERNAME")")$([[ -n "$SOCKS5_PASSWORD" ]] && printf ',\n    "password": %s' "$(json_string "$SOCKS5_PASSWORD")")
EOF_JSON
        ;;
    esac

    cat <<EOF_JSON
  },
  "masquerade": {
    "title": "Default Site",
    "message": "The requested site is temporarily unavailable."
  },
  "routes": [
    {
      "domains": [$(json_string "$NAIVE_DOMAIN")],
      "naive": true,
      "masquerade": {
        "reverse_proxy": $(json_string "$MASQUERADE_URL"),
        "preserve_host": false
      }
    }
EOF_JSON

    if [[ -f "$REVERSE_PROXY_FILE" ]]; then
      while IFS=$'\t' read -r domain target; do
        [[ -z "${domain:-}" || -z "${target:-}" ]] && continue
        cat <<EOF_JSON
    ,
    {
      "domains": [$(json_string "$domain")],
      "naive": false,
      "masquerade": {
        "reverse_proxy": $(json_string "$target"),
        "preserve_host": false
      }
    }
EOF_JSON
      done <"$REVERSE_PROXY_FILE"
    fi

    cat <<EOF_JSON
  ],
  "timeouts": {
    "read_header": "10s",
    "idle": "120s",
    "dial": "15s"
  }
}
EOF_JSON
  } >"$NAIVE_CONFIG"
}

write_configs() {
  mkdir -p "$BASE_DIR"
  write_naive_config
  chmod 600 "$NAIVE_CONFIG"
  ok "配置已生成: $NAIVE_CONFIG"
}

install_service() {
  cat >"/etc/systemd/system/$NAIVE_SERVICE" <<EOF_SERVICE
[Unit]
Description=naive-front standalone naive proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
ExecStart=$NAIVE_BIN -config $NAIVE_CONFIG
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable "$NAIVE_SERVICE" >/dev/null
  systemctl restart "$NAIVE_SERVICE"
  ok "systemd 服务已启动: $NAIVE_SERVICE"
}

show_status() {
  printf "${GREEN}\nnaive-front 状态${NC}\n"
  systemctl --no-pager status "$NAIVE_SERVICE" || true
  printf "${GREEN}\n监听端口${NC}\n"
  ss -tlnp 2>/dev/null | grep -E ':443\s' || true
  ss -ulnp 2>/dev/null | grep -E ':443\s' || true
}

install_naive() {
  if [[ -f "$NAIVE_CONFIG" ]]; then
    warn "检测到已有配置，进入更新 naive 节点配置流程"
    update_node_config
    return
  fi
  collect_node_config
  mkdir -p "$BASE_DIR"
  install_naive_binary
  write_configs
  install_service
  print_node_summary
}

print_node_summary() {
  load_state
  printf "${GREEN}\n节点信息${NC}\n"
  echo "域名:     $NAIVE_DOMAIN"
  echo "用户名:   $NAIVE_USERNAME"
  echo "密码:     $NAIVE_PASSWORD"
  echo "TCP 入站: $([[ "$ENABLE_TCP" == "true" ]] && echo "开启 (https://$NAIVE_DOMAIN:443)" || echo "关闭")"
  echo "QUIC 入站: $([[ "$ENABLE_QUIC" == "true" ]] && echo "开启 (quic://$NAIVE_DOMAIN:443)" || echo "关闭")"
  case "$OUTBOUND_TYPE" in
    direct) echo "出站:     direct (直连)" ;;
    socks5) echo "出站:     socks5://$SOCKS5_SERVER:$SOCKS5_PORT" ;;
    http)   echo "出站:     http://$SOCKS5_SERVER:$SOCKS5_PORT" ;;
  esac
}

manage_naive() {
  while true; do
    printf "${GREEN}\n管理 naive-front${NC}\n"
    echo "1. 关闭 naive-front"
    echo "2. 重启 naive-front"
    echo "3. 查看 naive-front 状态"
    echo "4. 查看节点信息"
    echo "0. 返回上一级"
    read -r -p "请选择: " choice || true
    case "$choice" in
      1) systemctl stop "$NAIVE_SERVICE"; ok "已关闭"; pause ;;
      2) systemctl restart "$NAIVE_SERVICE"; ok "已重启"; pause ;;
      3) show_status; pause ;;
      4) print_node_summary; pause ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

update_node_config() {
  load_state
  info "当前 naive 用户名:  ${NAIVE_USERNAME:-未设置}"
  info "当前 naive 域名:    ${NAIVE_DOMAIN:-未设置}"
  info "当前伪装网站:       ${MASQUERADE_URL:-未设置}"
  info "当前 TCP 入站:      ${ENABLE_TCP:-true}"
  info "当前 QUIC 入站:     ${ENABLE_QUIC:-true}"
  info "当前出站类型:       ${OUTBOUND_TYPE:-direct}"
  collect_node_config
  write_configs
  install_service
  print_node_summary
}

update_naive_binary() {
  if [[ ! -f "$NAIVE_BIN" ]]; then
    warn "naive-front 尚未安装"
    return
  fi
  install_naive_binary
  systemctl restart "$NAIVE_SERVICE"
  ok "naive-front 二进制已更新并重启"
}

add_reverse_proxy() {
  local domain target
  domain="$(prompt_value "域名（回车返回）" "" false)"
  [[ -z "$domain" ]] && return
  target="$(prompt_value "反向代理目标 URL（回车返回）" "" false)"
  [[ -z "$target" ]] && return
  mkdir -p "$BASE_DIR"
  if [[ -f "$REVERSE_PROXY_FILE" ]] && cut -f1 "$REVERSE_PROXY_FILE" | grep -Fxq "$domain"; then
    warn "域名已存在: $domain"
    return
  fi
  printf '%s\t%s\n' "$domain" "$target" >>"$REVERSE_PROXY_FILE"
  load_state
  write_configs
  systemctl restart "$NAIVE_SERVICE"
  ok "已添加反向代理: $domain -> $target"
}

delete_reverse_proxy() {
  if [[ ! -s "$REVERSE_PROXY_FILE" ]]; then
    warn "没有可删除的反向代理项"
    return
  fi
  mapfile -t entries <"$REVERSE_PROXY_FILE"
  local n=1 entry domain target
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r domain target <<<"$entry"
    printf "%d. %s -> %s\n" "$n" "$domain" "$target"
    n=$((n + 1))
  done
  local choice
  read -r -p "请选择要删除的序号: " choice || true
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
    warn "无效选择"
    return
  fi
  confirm_default_no "确认删除" || return
  : >"$REVERSE_PROXY_FILE.tmp"
  n=1
  for entry in "${entries[@]}"; do
    if (( n != choice )); then
      printf '%s\n' "$entry" >>"$REVERSE_PROXY_FILE.tmp"
    fi
    n=$((n + 1))
  done
  mv "$REVERSE_PROXY_FILE.tmp" "$REVERSE_PROXY_FILE"
  load_state
  write_configs
  systemctl restart "$NAIVE_SERVICE"
  ok "已删除反向代理"
}

update_reverse_proxy_menu() {
  while true; do
    printf "${GREEN}\n更新反向代理配置${NC}\n"
    echo "1. 添加反向代理"
    echo "2. 删除反向代理"
    echo "0. 返回上一级"
    read -r -p "请选择: " choice || true
    case "$choice" in
      1) add_reverse_proxy; pause ;;
      2) delete_reverse_proxy; pause ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

uninstall_naive() {
  confirm_default_no "是否确认卸载 naive-front" || return
  local delete_config=false
  confirm_default_no "是否删除配置目录 $BASE_DIR" && delete_config=true
  systemctl stop "$NAIVE_SERVICE" 2>/dev/null || true
  systemctl disable "$NAIVE_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$NAIVE_SERVICE"
  systemctl daemon-reload
  if [[ "$delete_config" == true ]]; then
    rm -rf "$BASE_DIR"
    ok "已卸载并删除配置目录 $BASE_DIR"
  else
    rm -f "$NAIVE_BIN"
    ok "已停止服务并删除二进制，配置已保留"
  fi
}

main_menu() {
  require_root
  while true; do
    printf "${GREEN}\nnaive-front 管理脚本（standalone 模式）${NC}\n"
    echo "1. 安装 naive-front"
    echo "2. 管理 naive-front"
    echo "3. 更新节点配置（用户名/密码/域名/出站等）"
    echo "4. 更新反向代理配置"
    echo "5. 仅更新 naive-front 二进制（保留配置）"
    echo "6. 卸载 naive-front"
    echo "0. 退出"
    read -r -p "请选择: " choice || true
    case "$choice" in
      1) install_naive; pause ;;
      2) manage_naive ;;
      3) update_node_config; pause ;;
      4) update_reverse_proxy_menu ;;
      5) update_naive_binary; pause ;;
      6) uninstall_naive; pause ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main_menu "$@"
