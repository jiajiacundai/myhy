#!/usr/bin/env bash

set -o pipefail

REPO="jiajiacundai/myhy"
RELEASE_TAG="ip-sentinel-latest"
INSTALL_DIR="/root/docker-compose/IP-Sentinel"
SERVICE_NAME="ip-sentinel.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
BIN_PATH="${INSTALL_DIR}/ip-sentinel-go"
IP_FILE="${INSTALL_DIR}/ips.txt"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
  C_DIM=""
  C_BOLD=""
fi

info() { printf "%s[信息]%s %s\n" "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf "%s[成功]%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s[警告]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
err() { printf "%s[错误]%s %s\n" "$C_RED" "$C_RESET" "$*"; }

ui_line() {
  printf "%s%s%s\n" "$C_CYAN" "========================================" "$C_RESET"
}

ui_rule() {
  printf "%s%s%s\n" "$C_DIM" "----------------------------------------" "$C_RESET"
}

ui_title() {
  local title="$1"
  printf "\n"
  ui_line
  printf "%s%s%s\n" "$C_BOLD$C_CYAN" "  ${title}" "$C_RESET"
  ui_line
}

ui_section() {
  local title="$1"
  printf "\n%s%s%s\n" "$C_BOLD$C_MAGENTA" ">> ${title}" "$C_RESET"
  ui_rule
}

ui_kv() {
  local key="$1"
  local value="${2:-未知}"
  printf "  %s%-16s%s %b\n" "$C_BLUE" "${key}:" "$C_RESET" "$value"
}

ui_menu_item() {
  local num="$1"
  local text="$2"
  printf "  %s%2s%s  %s\n" "$C_GREEN" "$num." "$C_RESET" "$text"
}

ui_prompt() {
  printf "%s%s%s" "$C_GREEN" "$1" "$C_RESET"
}

read_prompt() {
  local __var="$1"
  local prompt="$2"
  read -r -p "$(ui_prompt "$prompt")" "$__var"
}

status_value() {
  case "$1" in
    是|失败|不可用|未安装|未运行)
      printf "%s%s%s" "$C_RED" "$1" "$C_RESET"
      ;;
    否|成功|可用|已运行|已配置)
      printf "%s%s%s" "$C_GREEN" "$1" "$C_RESET"
      ;;
    *)
      printf "%s%s%s" "$C_YELLOW" "${1:-未知}" "$C_RESET"
      ;;
  esac
}

service_state() {
  command -v systemctl >/dev/null 2>&1 || { printf "不可用"; return 0; }
  systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || { printf "未安装"; return 0; }
  systemctl is-active --quiet "$SERVICE_NAME" && { printf "已运行"; return 0; }
  printf "未运行"
}

config_state() {
  [[ -s "$IP_FILE" ]] && { printf "已配置"; return 0; }
  printf "未配置"
}

pause() {
  read_prompt _ "按回车继续..."
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请使用 root 用户执行。"
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "未找到 systemctl，当前脚本需要 systemd 管理守护进程。"
    return 1
  fi
}

install_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v tar >/dev/null 2>&1 || missing+=("tar")

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  info "安装依赖: ${missing[*]} ca-certificates"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl tar ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl tar ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl tar ca-certificates
  else
    err "未找到 apt-get/dnf/yum，请手动安装 curl、tar、ca-certificates。"
    return 1
  fi
}

detect_platform() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      printf "linux-amd64"
      ;;
    aarch64|arm64)
      printf "linux-arm64"
      ;;
    *)
      err "不支持的 CPU 架构: ${arch}"
      return 1
      ;;
  esac
}

release_url() {
  local platform="$1"
  printf "https://github.com/%s/releases/download/%s/ip-sentinel-%s.tar.gz" "$REPO" "$RELEASE_TAG" "$platform"
}

detect_public_ip() {
  local version="$1"
  local curl_arg="-4"
  [[ "$version" == "6" ]] && curl_arg="-6"

  {
    curl "$curl_arg" -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || curl "$curl_arg" -fsS --max-time 8 https://api.ip.sb/ip 2>/dev/null \
    || curl "$curl_arg" -fsS --max-time 8 https://icanhazip.com 2>/dev/null
  } | tr -d '[:space:]'
}

detect_geo_json() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1

  curl -fsS --max-time 10 "https://ipapi.co/${ip}/json/" 2>/dev/null \
    || curl -fsS --max-time 10 "https://ipinfo.io/${ip}/json" 2>/dev/null \
    || curl -fsS --max-time 10 "https://api.ip.sb/geoip/${ip}" 2>/dev/null
}

extract_country_code() {
  grep -o '"'"$1"'":"[A-Z][A-Z]"' | head -n 1 | sed 's/.*:"\([A-Z][A-Z]\)"/\1/'
}

detect_youtube_info() {
  local version="$1"
  local curl_arg="-4"
  local body region sent_cn="0" sent_label="未知"
  [[ "$version" == "6" ]] && curl_arg="-6"

  body="$(curl "$curl_arg" -A "Mozilla/5.0" -fsSL --max-time 15 https://www.youtube.com/premium 2>/dev/null | head -c 2097152)"
  [[ -n "$body" ]] || return 0

  if printf "%s" "$body" | grep -q 'www\.google\.cn'; then
    sent_cn="1"
  fi

  region="$(printf "%s" "$body" | extract_country_code "INNERTUBE_CONTEXT_GL")"
  [[ -z "$region" ]] && region="$(printf "%s" "$body" | extract_country_code "countryCode")"
  [[ -z "$region" ]] && region="$(printf "%s" "$body" | extract_country_code "contentRegion")"
  [[ -z "$region" ]] && region="$(printf "%s" "$body" | extract_country_code "GL")"

  if [[ "$sent_cn" == "1" && -z "$region" ]]; then
    region="CN"
  fi

  if [[ "$sent_cn" == "1" || "$region" == "CN" ]]; then
    sent_label="是"
  elif [[ -n "$region" ]]; then
    sent_label="否"
  fi

  printf "%s\t%s" "$region" "$sent_label"
}

json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

print_exit_info() {
  local version="$1"
  local label="$2"
  local json ip country country_code region city isp org asn timezone youtube_info youtube_region youtube_sent

  ui_section "${label} 出口信息"
  ip="$(detect_public_ip "$version")"
  youtube_info="$(detect_youtube_info "$version")"
  youtube_region="${youtube_info%%$'\t'*}"
  youtube_sent="${youtube_info#*$'\t'}"
  [[ "$youtube_sent" == "$youtube_info" ]] && youtube_sent="未知"
  json="$(detect_geo_json "$ip")"

  if [[ -z "$json" ]]; then
    if [[ -n "$ip" ]]; then
      ui_kv "IP" "$ip"
      warn "${label} 地理信息接口不可用，仅显示出口 IP。"
    else
      warn "${label} 出口不可用或外部接口无法访问。"
    fi
    ui_kv "YouTube 区域" "${youtube_region:-未识别}"
    ui_kv "YouTube 送中" "$(status_value "${youtube_sent:-未知}")"
    return 0
  fi

  ip="$(printf "%s" "$json" | json_value "ip")"
  [[ -z "$ip" ]] && ip="$(printf "%s" "$json" | json_value "query")"
  country="$(printf "%s" "$json" | json_value "country_name")"
  country_code="$(printf "%s" "$json" | json_value "country_code")"
  [[ -z "$country_code" ]] && country_code="$(printf "%s" "$json" | json_value "countryCode")"
  [[ -z "$country" ]] && country="$(printf "%s" "$json" | json_value "country")"
  if [[ -n "$country" && -n "$country_code" && "$country" != "$country_code" ]]; then
    country="${country} (${country_code})"
  elif [[ -z "$country" ]]; then
    country="$country_code"
  fi
  region="$(printf "%s" "$json" | json_value "region")"
  [[ -z "$region" ]] && region="$(printf "%s" "$json" | json_value "regionName")"
  city="$(printf "%s" "$json" | json_value "city")"
  isp="$(printf "%s" "$json" | json_value "isp")"
  org="$(printf "%s" "$json" | json_value "organization")"
  [[ -z "$org" ]] && org="$(printf "%s" "$json" | json_value "org")"
  [[ -z "$org" ]] && org="$(printf "%s" "$json" | json_value "org_name")"
  asn="$(printf "%s" "$json" | json_value "asn")"
  [[ -z "$asn" ]] && asn="$(printf "%s" "$json" | sed -n 's/.*"asn"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/AS\1/p' | head -n 1)"
  timezone="$(printf "%s" "$json" | json_value "timezone")"

  ui_kv "IP" "${ip:-未知}"
  ui_kv "国家/地区" "${country:-未知}"
  ui_kv "省州" "${region:-未知}"
  ui_kv "城市" "${city:-未知}"
  ui_kv "运营商/组织" "${isp:-${org:-未知}}"
  [[ -n "$asn" ]] && ui_kv "ASN" "$asn"
  [[ -n "$timezone" ]] && ui_kv "时区" "$timezone"
  ui_kv "YouTube 区域" "${youtube_region:-未识别}"
  ui_kv "YouTube 送中" "$(status_value "${youtube_sent:-未知}")"
}

detect_current_exit() {
  install_dependencies || return 1
  ui_title "检测当前出口信息"
  print_exit_info "4" "IPv4"
  print_exit_info "6" "IPv6"
}

validate_ipv4() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
}

validate_ipv6() {
  local ip="$1"
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" != *" "* ]] || return 1
}

get_ips() {
  local stack="$1"
  [[ -f "$IP_FILE" ]] || return 0
  awk -v stack="$stack" '$1 == stack && $2 != "" {print $2}' "$IP_FILE"
}

join_list() {
  if [[ "$#" -eq 0 ]]; then
    printf "未配置"
    return
  fi
  local IFS=", "
  printf "%s" "$*"
}

print_current_config() {
  local v4s=()
  local v6s=()
  mapfile -t v4s < <(get_ips "v4")
  mapfile -t v6s < <(get_ips "v6")

  ui_kv "当前 IPv4" "$(join_list "${v4s[@]}")"
  ui_kv "当前 IPv6" "$(join_list "${v6s[@]}")"
}

split_input_ips() {
  local raw="$1"
  printf "%s" "$raw" | tr ',;' '\n' | awk '{$1=$1; print}' | sed '/^$/d'
}

prompt_stack_ips() {
  local stack="$1"
  local label="$2"
  local auto_ip="$3"
  local input token ok_all
  PROMPT_RESULT=()

  while true; do
    if [[ -n "$auto_ip" ]]; then
      info "自动探测 ${label}: ${auto_ip}"
    else
      warn "自动探测 ${label}: 未获取"
    fi

    read_prompt input "请输入 ${label}（回车使用自动探测；输入 1 不填入；多个用逗号分隔）: "
    if [[ "$input" == "1" ]]; then
      PROMPT_RESULT=()
      return 0
    fi
    if [[ -z "$input" ]]; then
      if [[ -z "$auto_ip" ]]; then
        PROMPT_RESULT=()
        return 0
      fi
      input="$auto_ip"
    fi

    PROMPT_RESULT=()
    ok_all=1
    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      if [[ "$stack" == "v4" ]]; then
        if ! validate_ipv4 "$token"; then
          err "IPv4 格式不正确: ${token}"
          ok_all=0
          break
        fi
      else
        if ! validate_ipv6 "$token"; then
          err "IPv6 格式不正确: ${token}"
          ok_all=0
          break
        fi
      fi
      PROMPT_RESULT+=("$token")
    done < <(split_input_ips "$input")

    [[ "$ok_all" == "1" ]] && return 0
  done
}

prompt_full_config() {
  local auto_v4 auto_v6
  local v4s=()
  local v6s=()

  print_current_config
  auto_v4="$(detect_public_ip 4)"
  auto_v6="$(detect_public_ip 6)"

  prompt_stack_ips "v4" "IPv4" "$auto_v4"
  v4s=("${PROMPT_RESULT[@]}")
  prompt_stack_ips "v6" "IPv6" "$auto_v6"
  v6s=("${PROMPT_RESULT[@]}")

  CONFIG_V4=("${v4s[@]}")
  CONFIG_V6=("${v6s[@]}")
}

write_ip_file() {
  mkdir -p "$INSTALL_DIR"
  {
    printf "# IP-Sentinel 出口 IP 配置，每行格式: v4 1.2.3.4 或 v6 2001:db8::1\n"
    for ip in "${CONFIG_V4[@]}"; do
      printf "v4 %s\n" "$ip"
    done
    for ip in "${CONFIG_V6[@]}"; do
      printf "v6 %s\n" "$ip"
    done
  } > "$IP_FILE"
  chmod 600 "$IP_FILE"
  ok "已写入配置: ${IP_FILE}"
}

generate_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=IP-Sentinel IP maintenance service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -mode=loop -task=wheel -interval=20m -ip-version=dual -ip-file=${IP_FILE} -region-config=${INSTALL_DIR}/configs/los_angeles.json -keywords=${INSTALL_DIR}/data/keywords/kw_US.txt -ua=${INSTALL_DIR}/data/user_agents.txt -cookie-dir=${INSTALL_DIR}/.ips-cookies
Restart=always
RestartSec=20
KillSignal=SIGINT
TimeoutStopSec=30
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "已生成 systemd 服务: ${SERVICE_FILE}"
}

download_and_install() {
  local platform asset_url tmp archive
  platform="$(detect_platform)" || return 1
  asset_url="$(release_url "$platform")"
  tmp="$(mktemp -d)"
  archive="${tmp}/ip-sentinel-${platform}.tar.gz"

  mkdir -p "$INSTALL_DIR"
  info "下载 IP-Sentinel: ${asset_url}"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$asset_url"; then
    rm -rf "$tmp"
    err "下载失败，请确认 release 文件存在。"
    return 1
  fi

  tar -xzf "$archive" -C "$INSTALL_DIR"
  rm -rf "$tmp"
  chmod +x "$BIN_PATH"
  ok "已安装到: ${INSTALL_DIR}"
}

restart_service_if_exists() {
  if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    if systemctl restart "$SERVICE_NAME"; then
      ok "已重启 ${SERVICE_NAME}"
    else
      err "重启 ${SERVICE_NAME} 失败，请执行 systemctl status ${SERVICE_NAME} 查看。"
      return 1
    fi
  else
    warn "服务尚未安装，配置已保存。"
  fi
}

install_ip_sentinel() {
  require_root
  require_systemd || return 1
  install_dependencies || return 1

  ui_title "安装 IP-Sentinel"
  prompt_full_config
  download_and_install || return 1
  write_ip_file
  generate_service
  systemctl enable --now "$SERVICE_NAME"
  ok "IP-Sentinel 已启动。"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

stop_ip_sentinel() {
  require_root
  if systemctl stop "$SERVICE_NAME"; then
    ok "已关闭 ${SERVICE_NAME}"
  else
    err "关闭 ${SERVICE_NAME} 失败。"
  fi
}

restart_ip_sentinel() {
  require_root
  if systemctl restart "$SERVICE_NAME"; then
    ok "已重启 ${SERVICE_NAME}"
  else
    err "重启 ${SERVICE_NAME} 失败。"
  fi
}

status_ip_sentinel() {
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

add_ip() {
  local stack="$1"
  local label="$2"
  local input token exists
  mkdir -p "$INSTALL_DIR"
  while true; do
    read_prompt input "请输入要添加的 ${label}（多个用逗号分隔，0 返回）: "
    [[ "$input" == "0" ]] && return 0
    [[ -n "$input" ]] || continue

    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      if [[ "$stack" == "v4" ]]; then
        validate_ipv4 "$token" || { err "IPv4 格式不正确: ${token}"; continue; }
      else
        validate_ipv6 "$token" || { err "IPv6 格式不正确: ${token}"; continue; }
      fi
      exists="$(awk -v stack="$stack" -v ip="$token" '$1 == stack && $2 == ip {print "yes"}' "$IP_FILE" 2>/dev/null)"
      if [[ "$exists" == "yes" ]]; then
        warn "${token} 已存在，跳过。"
      else
        printf "%s %s\n" "$stack" "$token" >> "$IP_FILE"
        ok "已添加 ${token}"
      fi
    done < <(split_input_ips "$input")
    restart_service_if_exists
    return 0
  done
}

delete_ip() {
  local stack="$1"
  local label="$2"
  local ips=()
  local choice ip confirm tmp

  mapfile -t ips < <(get_ips "$stack")
  if [[ ${#ips[@]} -eq 0 ]]; then
    warn "当前没有 ${label} 配置。"
    return 0
  fi

  ui_section "当前 ${label} 列表"
  local i
  for i in "${!ips[@]}"; do
    ui_menu_item "$((i + 1))" "${ips[$i]}"
  done
  ui_menu_item "0" "返回上一级"

  read_prompt choice "请选择要删除的编号: "
  [[ "$choice" == "0" ]] && return 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ips[@]} )); then
    err "无效编号。"
    return 1
  fi

  ip="${ips[$((choice - 1))]}"
  read_prompt confirm "确认删除 ${ip}? [y/N]: "
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    warn "已取消删除。"
    return 0
  fi

  tmp="$(mktemp)"
  awk -v stack="$stack" -v ip="$ip" '!(($1 == stack) && ($2 == ip))' "$IP_FILE" > "$tmp"
  mv "$tmp" "$IP_FILE"
  chmod 600 "$IP_FILE"
  ok "已删除 ${ip}"
  restart_service_if_exists
}

update_config() {
  require_root
  require_systemd || return 1
  install_dependencies || return 1
  ui_title "更新 IP-Sentinel 配置"
  prompt_full_config
  write_ip_file
  generate_service
  restart_service_if_exists
}

uninstall_ip_sentinel() {
  require_root
  local confirm delete_dir

  ui_title "卸载 IP-Sentinel"
  read_prompt confirm "是否卸载 IP-Sentinel 服务? [y/N]: "
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    warn "已取消卸载。"
    return 0
  fi

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  ok "已卸载 systemd 服务。"

  read_prompt delete_dir "是否删除 ${INSTALL_DIR} 目录? [y/N]: "
  if [[ "$delete_dir" =~ ^[Yy]$ ]]; then
    rm -rf "$INSTALL_DIR"
    ok "已删除 ${INSTALL_DIR}"
  else
    warn "保留目录: ${INSTALL_DIR}"
  fi
}

manage_menu() {
  while true; do
    ui_title "管理 IP-Sentinel"
    ui_menu_item "1" "关闭 IP-Sentinel"
    ui_menu_item "2" "重启 IP-Sentinel"
    ui_menu_item "3" "查看 IP-Sentinel 状态"
    ui_menu_item "0" "返回上一级"
    read_prompt choice "请选择: "
    case "$choice" in
      1) stop_ip_sentinel; pause ;;
      2) restart_ip_sentinel; pause ;;
      3) status_ip_sentinel; pause ;;
      0) return 0 ;;
      *) err "无效选择。";;
    esac
  done
}

config_menu() {
  while true; do
    ui_title "管理 IP-Sentinel 配置"
    print_current_config
    printf "\n"
    ui_menu_item "1" "添加 IPv4"
    ui_menu_item "2" "删除 IPv4"
    ui_menu_item "3" "添加 IPv6"
    ui_menu_item "4" "删除 IPv6"
    ui_menu_item "5" "更新 IP-Sentinel 配置"
    ui_menu_item "0" "返回上一级"
    read_prompt choice "请选择: "
    case "$choice" in
      1) add_ip "v4" "IPv4"; pause ;;
      2) delete_ip "v4" "IPv4"; pause ;;
      3) add_ip "v6" "IPv6"; pause ;;
      4) delete_ip "v6" "IPv6"; pause ;;
      5) update_config; pause ;;
      0) return 0 ;;
      *) err "无效选择。";;
    esac
  done
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    ui_title "IP-Sentinel 彩色管理脚本"
    ui_kv "安装目录" "$INSTALL_DIR"
    ui_kv "服务名称" "$SERVICE_NAME"
    ui_kv "服务状态" "$(status_value "$(service_state)")"
    ui_kv "配置状态" "$(status_value "$(config_state)")"
    printf "\n"
    ui_menu_item "1" "安装 IP-Sentinel"
    ui_menu_item "2" "管理 IP-Sentinel"
    ui_menu_item "3" "管理 IP-Sentinel 配置"
    ui_menu_item "4" "检测当前出口信息"
    ui_menu_item "5" "卸载 IP-Sentinel"
    ui_menu_item "0" "退出"
    read_prompt choice "请选择: "
    case "$choice" in
      1) install_ip_sentinel; pause ;;
      2) manage_menu ;;
      3) config_menu ;;
      4) detect_current_exit; pause ;;
      5) uninstall_ip_sentinel; pause ;;
      0) exit 0 ;;
      *) err "无效选择。"; pause ;;
    esac
  done
}

main_menu
