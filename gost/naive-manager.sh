#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/root/docker-compose/sing-box"
SING_BOX_BIN="$BASE_DIR/sing-box"
NAIVE_BIN="$BASE_DIR/naive-front"
STATE_FILE="$BASE_DIR/manager-state.env"
REVERSE_PROXY_FILE="$BASE_DIR/reverse-proxies.tsv"
SING_BOX_CONFIG="$BASE_DIR/sing-box.json"
NAIVE_CONFIG="$BASE_DIR/naive-front.json"
SING_BOX_SERVICE="sing-box-naive.service"
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
  MASQUERADE_URL="https://global.toyota"
  ENABLE_SOCKS5="false"
  SOCKS5_SERVER=""
  SOCKS5_PORT="10808"
  SOCKS5_USERNAME=""
  SOCKS5_PASSWORD=""
  ENABLE_NAIVE_TCP="false"
  SING_BOX_MIXED_LISTEN="127.0.0.1"
  SING_BOX_MIXED_PORT="10081"
  CERT_FILE="/root/cert/cert.crt"
  KEY_FILE="/root/cert/private.key"
  SING_BOX_QUIC_LISTEN="::"
  SING_BOX_QUIC_PORT="443"
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
ENABLE_SOCKS5=$(printf '%q' "$ENABLE_SOCKS5")
SOCKS5_SERVER=$(printf '%q' "$SOCKS5_SERVER")
SOCKS5_PORT=$(printf '%q' "$SOCKS5_PORT")
SOCKS5_USERNAME=$(printf '%q' "$SOCKS5_USERNAME")
SOCKS5_PASSWORD=$(printf '%q' "$SOCKS5_PASSWORD")
ENABLE_NAIVE_TCP=$(printf '%q' "$ENABLE_NAIVE_TCP")
SING_BOX_MIXED_LISTEN=$(printf '%q' "$SING_BOX_MIXED_LISTEN")
SING_BOX_MIXED_PORT=$(printf '%q' "$SING_BOX_MIXED_PORT")
CERT_FILE=$(printf '%q' "$CERT_FILE")
KEY_FILE=$(printf '%q' "$KEY_FILE")
SING_BOX_QUIC_LISTEN=$(printf '%q' "$SING_BOX_QUIC_LISTEN")
SING_BOX_QUIC_PORT=$(printf '%q' "$SING_BOX_QUIC_PORT")
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
    curl -fsSL "$url" -o "$output"
  elif need_cmd wget; then
    wget -qO "$output" "$url"
  else
    err "需要 curl 或 wget"
    exit 1
  fi
}

github_latest_release_json() {
  local repo="$1"
  if need_cmd curl; then
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest"
  else
    wget -qO- "https://api.github.com/repos/${repo}/releases/latest"
  fi
}

install_sing_box_binary() {
  local arch asset_url tmp archive
  arch="$(detect_arch)"
  tmp="$(mktemp -d)"
  archive="$tmp/sing-box.tar.gz"
  info "下载 sing-box 最新版..."
  asset_url="$(github_latest_release_json SagerNet/sing-box | tr ',' '\n' | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*linux-'"$arch"'\.tar\.gz\)".*/\1/p' | head -n 1)"
  if [[ -z "$asset_url" ]]; then
    rm -rf "$tmp"
    err "未找到 sing-box linux-${arch} release 资源"
    exit 1
  fi
  download_file "$asset_url" "$archive"
  tar -xzf "$archive" -C "$tmp"
  find "$tmp" -type f -name sing-box -exec install -m 0755 {} "$SING_BOX_BIN" \;
  find "$tmp" -type f -name 'libcronet.*' -exec cp {} "$BASE_DIR" \; 2>/dev/null || true
  rm -rf "$tmp"
  ok "sing-box 已安装到 $SING_BOX_BIN"
}

install_naive_binary() {
  local arch asset_name asset_url
  arch="$(detect_arch)"
  asset_name="${NAIVE_ASSET_PREFIX}-${arch}"
  asset_url="https://github.com/${NAIVE_RELEASE_REPO}/releases/download/${NAIVE_RELEASE_TAG}/${asset_name}"
  info "下载 naive-front: $asset_name"
  download_file "$asset_url" "$NAIVE_BIN"
  chmod 0755 "$NAIVE_BIN"
  ok "naive-front 已安装到 $NAIVE_BIN"
}

collect_node_config() {
  load_state
  local generated
  generated="$(random_string 12)"
  NAIVE_USERNAME="$(prompt_value "naive username，回车随机生成" "${NAIVE_USERNAME:-$generated}" false)"
  generated="$(random_string 18)"
  NAIVE_PASSWORD="$(prompt_value "naive password，回车随机生成" "${NAIVE_PASSWORD:-$generated}" false)"
  NAIVE_DOMAIN="$(prompt_value "naive 域名" "$NAIVE_DOMAIN" true)"
  MASQUERADE_URL="$(prompt_value "伪装网站" "${MASQUERADE_URL:-https://global.toyota}" false)"
  if confirm_default_no "是否启用 socks5 转发"; then
    ENABLE_SOCKS5="true"
    SOCKS5_SERVER="$(prompt_value "转发 ip/域名" "$SOCKS5_SERVER" true)"
    SOCKS5_PORT="$(prompt_value "转发 socks5 端口" "${SOCKS5_PORT:-10808}" false)"
    SOCKS5_USERNAME="$(prompt_value "转发 socks5 username，可为空" "$SOCKS5_USERNAME" false)"
    SOCKS5_PASSWORD="$(prompt_value "转发 socks5 password，可为空" "$SOCKS5_PASSWORD" false)"
  else
    ENABLE_SOCKS5="false"
    SOCKS5_SERVER=""
    SOCKS5_PORT="10808"
    SOCKS5_USERNAME=""
    SOCKS5_PASSWORD=""
  fi
  if confirm_default_no "是否启用 naive TCP"; then
    ENABLE_NAIVE_TCP="true"
  else
    ENABLE_NAIVE_TCP="false"
  fi
  CERT_FILE="$(prompt_value "TLS 证书文件" "$CERT_FILE" true)"
  KEY_FILE="$(prompt_value "TLS 私钥文件" "$KEY_FILE" true)"
  save_state
}

write_sing_box_config() {
  local final="direct-out"
  [[ "$ENABLE_SOCKS5" == "true" ]] && final="socks-out"
  {
    cat <<EOF_JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
EOF_JSON
    if [[ "$ENABLE_NAIVE_TCP" == "true" ]]; then
      cat <<EOF_JSON
    {
      "type": "mixed",
      "tag": "naive-front-in",
      "listen": $(json_string "$SING_BOX_MIXED_LISTEN"),
      "listen_port": $SING_BOX_MIXED_PORT
    },
EOF_JSON
    fi
    cat <<EOF_JSON
    {
      "type": "naive",
      "tag": "naive-in",
      "network": "udp",
      "listen": $(json_string "$SING_BOX_QUIC_LISTEN"),
      "listen_port": $SING_BOX_QUIC_PORT,
      "users": [
        {
          "username": $(json_string "$NAIVE_USERNAME"),
          "password": $(json_string "$NAIVE_PASSWORD")
        }
      ],
      "quic_congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": $(json_string "$CERT_FILE"),
        "key_path": $(json_string "$KEY_FILE")
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
EOF_JSON
    if [[ "$ENABLE_SOCKS5" == "true" ]]; then
      cat <<EOF_JSON
    ,
    {
      "type": "socks",
      "tag": "socks-out",
      "server": $(json_string "$SOCKS5_SERVER"),
      "server_port": $SOCKS5_PORT,
      "version": "5"
EOF_JSON
      [[ -n "$SOCKS5_USERNAME" ]] && printf ',\n      "username": %s' "$(json_string "$SOCKS5_USERNAME")"
      [[ -n "$SOCKS5_PASSWORD" ]] && printf ',\n      "password": %s' "$(json_string "$SOCKS5_PASSWORD")"
      printf '\n    }\n'
    fi
    cat <<EOF_JSON
  ],
  "route": {
    "final": $(json_string "$final")
  }
}
EOF_JSON
  } >"$SING_BOX_CONFIG"
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
  }
EOF_JSON
    if [[ "$ENABLE_NAIVE_TCP" == "true" ]]; then
      cat <<EOF_JSON
  ,
  "forward_proxy": {
    "enabled": true,
    "address": $(json_string "${SING_BOX_MIXED_LISTEN}:${SING_BOX_MIXED_PORT}"),
    "tls": false
  }
EOF_JSON
    fi
    cat <<EOF_JSON
  ,
  "masquerade": {
    "title": "Default Site",
    "message": "The requested site is temporarily unavailable."
  },
  "routes": [
    {
      "domains": [$(json_string "$NAIVE_DOMAIN")],
      "naive": $ENABLE_NAIVE_TCP,
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
  write_sing_box_config
  write_naive_config
  chmod 600 "$SING_BOX_CONFIG" "$NAIVE_CONFIG"
  ok "配置已生成: $SING_BOX_CONFIG, $NAIVE_CONFIG"
}

install_services() {
  cat >"/etc/systemd/system/$SING_BOX_SERVICE" <<EOF_SERVICE
[Unit]
Description=sing-box naive backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
ExecStart=$SING_BOX_BIN run -c $SING_BOX_CONFIG
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  cat >"/etc/systemd/system/$NAIVE_SERVICE" <<EOF_SERVICE
[Unit]
Description=naive-front camouflage proxy
After=network-online.target $SING_BOX_SERVICE
Wants=network-online.target
Requires=$SING_BOX_SERVICE

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
ExecStart=$NAIVE_BIN -config $NAIVE_CONFIG
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable "$SING_BOX_SERVICE" "$NAIVE_SERVICE" >/dev/null
  systemctl restart "$SING_BOX_SERVICE" "$NAIVE_SERVICE"
  ok "systemd 服务已启动: $SING_BOX_SERVICE, $NAIVE_SERVICE"
}

show_naive_status() {
  printf "${GREEN}\nnaive-front 状态${NC}\n"
  systemctl --no-pager status "$NAIVE_SERVICE" || true
  printf "${GREEN}\nsing-box 状态${NC}\n"
  systemctl --no-pager status "$SING_BOX_SERVICE" || true
}

install_naive() {
  if [[ -f "$SING_BOX_CONFIG" || -f "$NAIVE_CONFIG" ]]; then
    warn "检测到已有配置，进入更新 naive 节点配置"
    update_node_config
    return
  fi
  local install_naive_bin=false install_sing_box_bin=false
  confirm_default_yes "是否安装 naive-front" && install_naive_bin=true
  confirm_default_yes "是否安装 sing-box" && install_sing_box_bin=true
  collect_node_config
  mkdir -p "$BASE_DIR"
  [[ "$install_sing_box_bin" == true ]] && install_sing_box_binary
  [[ "$install_naive_bin" == true ]] && install_naive_binary
  write_configs
  apply_tcp_tuning
  install_services
}

# apply_tcp_tuning unlocks Linux TCP autotune so that HTTP/2 CONNECT tunnels
# (sing-box naive TCP, udp_over_tcp) can saturate a high-BDP cross-border link.
# Defaults leave net.core.{r,w}mem_max at 208 KiB on Debian 12/13, which caps
# the receive window even when the application-layer H2 buffer is generous, so
# upload throughput collapses to RTT-bound minutes into a session. We do not
# touch tcp_congestion_control — BBR is unavailable on minimal/cloud kernels,
# and the kernel-chosen default (cubic/reno) is fine once the buffers and
# bufferbloat knobs are sane.
apply_tcp_tuning() {
  local conf=/etc/sysctl.d/99-naive-front.conf
  info "写入 TCP 调优 ${conf}"
  cat >"$conf" <<'EOF_SYSCTL'
# Installed by naive-manager.sh — raise TCP autotune ceilings so HTTP/2 CONNECT
# tunnels (sing-box naive TCP / udp_over_tcp) can saturate high-BDP links.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
# Limit unsent bytes per socket to 128 KiB to keep TCP feedback fresh and
# avoid bufferbloat starving the rest of the box under heavy upload.
net.ipv4.tcp_notsent_lowat = 131072
# Long-lived CONNECT tunnels often idle briefly; without this they are reset
# back to the initial window after every quiet period, producing the
# "starts fast then keeps slowing down" symptom.
net.ipv4.tcp_slow_start_after_idle = 0
# Cross-border paths sometimes blackhole MTU-1500 packets; let TCP probe down.
net.ipv4.tcp_mtu_probing = 1
# TCP Fast Open both directions — shaves a round-trip on the many short
# connections sing-box forwards through naive-front.
net.ipv4.tcp_fastopen = 3
EOF_SYSCTL
  if sysctl --system >/dev/null 2>&1; then
    ok "已应用 TCP 调优"
  else
    warn "sysctl --system 返回非零，请手动检查 ${conf}"
  fi
}

manage_naive() {
  while true; do
    printf "${GREEN}\n管理 naive${NC}\n"
    echo "1. 关闭 naive"
    echo "2. 重启 naive"
    echo "3. 查看 naive 状态"
    echo "0. 返回上一级"
    read -r -p "请选择: " choice || true
    case "$choice" in
      1) systemctl stop "$NAIVE_SERVICE" "$SING_BOX_SERVICE"; ok "已关闭 naive"; pause ;;
      2) systemctl restart "$SING_BOX_SERVICE" "$NAIVE_SERVICE"; ok "已重启 naive"; pause ;;
      3) show_naive_status; pause ;;
      0) return ;;
      *) warn "无效选项" ;;
    esac
  done
}

update_node_config() {
  load_state
  info "当前 naive 用户名: ${NAIVE_USERNAME:-未设置}"
  info "当前 naive 域名: ${NAIVE_DOMAIN:-未设置}"
  info "当前伪装网站: ${MASQUERADE_URL:-未设置}"
  if [[ "$ENABLE_SOCKS5" == "true" ]]; then
    info "当前 sing-box 出站: socks5://${SOCKS5_SERVER}:${SOCKS5_PORT}"
  else
    info "当前 sing-box 出站: direct"
  fi
  if [[ "$ENABLE_NAIVE_TCP" == "true" ]]; then
    info "当前 naive TCP: 启用，naive-front -> mixed://${SING_BOX_MIXED_LISTEN}:${SING_BOX_MIXED_PORT}"
  else
    info "当前 naive TCP: 未启用"
  fi
  info "当前 sing-box QUIC 入站: udp://[${SING_BOX_QUIC_LISTEN}]:${SING_BOX_QUIC_PORT}"
  collect_node_config
  write_configs
  apply_tcp_tuning
  install_services
}

add_reverse_proxy() {
  local domain target
  domain="$(prompt_value "域名，为空返回" "" false)"
  [[ -z "$domain" ]] && return
  target="$(prompt_value "反向代理网站，为空返回" "" false)"
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
    printf "${GREEN}\n更新 naive 反向代理配置${NC}\n"
    echo "1. 添加 naive 反向代理"
    echo "2. 删除 naive 反向代理"
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
  confirm_default_no "是否确认卸载 naive" || return
  local delete_config=false
  confirm_default_no "是否删除配置" && delete_config=true
  systemctl stop "$NAIVE_SERVICE" "$SING_BOX_SERVICE" 2>/dev/null || true
  systemctl disable "$NAIVE_SERVICE" "$SING_BOX_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$NAIVE_SERVICE" "/etc/systemd/system/$SING_BOX_SERVICE"
  rm -f /etc/sysctl.d/99-naive-front.conf
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload
  if [[ "$delete_config" == true ]]; then
    rm -rf "$BASE_DIR"
    ok "已卸载并删除配置目录 $BASE_DIR"
  else
    rm -f "$NAIVE_BIN" "$SING_BOX_BIN"
    ok "已停止服务并删除二进制，配置已保留"
  fi
}

main_menu() {
  require_root
  while true; do
    printf "${GREEN}\nnaive 管理脚本${NC}\n"
    echo "1. 安装 naive"
    echo "2. 管理 naive"
    echo "3. 更新 naive 节点配置"
    echo "4. 更新 naive 反向代理配置"
    echo "5. 卸载 naive"
    echo "0. 退出"
    read -r -p "请选择: " choice || true
    case "$choice" in
      1) install_naive; pause ;;
      2) manage_naive ;;
      3) update_node_config; pause ;;
      4) update_reverse_proxy_menu ;;
      5) uninstall_naive; pause ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

main_menu "$@"
