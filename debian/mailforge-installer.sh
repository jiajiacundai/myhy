#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/root/docker-compose/openclaw/mailforge"
DATA_DIR="${INSTALL_DIR}/data"
BINARY_PATH="${INSTALL_DIR}/mailforge"
CONFIG_PATH="${INSTALL_DIR}/config.toml"
SERVICE_NAME="mailforge"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GITHUB_REPO="jiajiacundai/myhy"
RELEASE_TAG="${MAILFORGE_RELEASE_TAG:-mailforge-latest}"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

pause() {
  if [[ -t 0 && -t 1 ]]; then
    read -r -e -p "按回车继续..." _
  else
    read -r -p "按回车继续..." _
  fi
}

readline_available() {
  [[ -t 0 && -t 1 ]]
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "请使用 root 运行此脚本。"
  fi
}

require_linux_systemd() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "当前脚本仅支持 Linux 系统。"
  fi
  if ! command_exists systemctl; then
    die "未检测到 systemctl，当前系统不支持按此脚本方式安装。"
  fi
}

detect_package_manager() {
  if command_exists apt-get; then
    echo "apt"
  elif command_exists dnf; then
    echo "dnf"
  elif command_exists yum; then
    echo "yum"
  elif command_exists zypper; then
    echo "zypper"
  elif command_exists pacman; then
    echo "pacman"
  elif command_exists apk; then
    echo "apk"
  else
    echo ""
  fi
}

install_curl() {
  if command_exists curl; then
    return
  fi

  local manager
  manager="$(detect_package_manager)"
  [[ -n "${manager}" ]] || die "未找到支持的包管理器，无法自动安装 curl。"

  log "未检测到 curl，正在自动安装。"
  case "${manager}" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
      ;;
    dnf)
      dnf install -y curl ca-certificates
      ;;
    yum)
      yum install -y curl ca-certificates
      ;;
    zypper)
      zypper --non-interactive install curl ca-certificates
      ;;
    pacman)
      pacman -Sy --noconfirm curl ca-certificates
      ;;
    apk)
      apk add --no-cache curl ca-certificates
      ;;
  esac
}

install_python_for_probe() {
  if [[ -n "$(detect_python)" ]]; then
    return
  fi

  local manager
  manager="$(detect_package_manager)"
  [[ -n "${manager}" ]] || die "未找到支持的包管理器，无法自动安装 Python。"

  log "未检测到 Python，正在自动安装以完成 SMTP 公网探测。"
  case "${manager}" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y python3
      ;;
    dnf)
      dnf install -y python3
      ;;
    yum)
      yum install -y python3
      ;;
    zypper)
      zypper --non-interactive install python3
      ;;
    pacman)
      pacman -Sy --noconfirm python
      ;;
    apk)
      apk add --no-cache python3
      ;;
  esac
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt_with_default() {
  local label="$1"
  local default_value="$2"
  local value

  if readline_available; then
    if [[ -n "${default_value}" ]]; then
      read -r -e -i "${default_value}" -p "${label}: " value
    else
      read -r -e -p "${label}: " value
    fi
    printf '%s' "${value}"
  else
    if [[ -n "${default_value}" ]]; then
      read -r -p "${label} [${default_value}]: " value
      printf '%s' "${value:-$default_value}"
    else
      read -r -p "${label}: " value
      printf '%s' "${value}"
    fi
  fi
}

prompt_secret_with_default() {
  local label="$1"
  local default_value="${2:-}"
  local value

  if readline_available; then
    if [[ -n "${default_value}" ]]; then
      read -r -s -e -i "${default_value}" -p "${label}: " value
    else
      read -r -s -e -p "${label}: " value
    fi
    printf '\n' >&2
    printf '%s' "${value}"
  else
    if [[ -n "${default_value}" ]]; then
      read -r -s -p "${label} [保留现有值请直接回车]: " value
      printf '\n' >&2
      printf '%s' "${value:-$default_value}"
    else
      read -r -s -p "${label}: " value
      printf '\n' >&2
      printf '%s' "${value}"
    fi
  fi
}

confirm() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local suffix="[y/N]"
  local answer

  if [[ "${default_answer}" =~ ^[Yy]$ ]]; then
    suffix="[Y/n]"
  fi

  if readline_available; then
    read -r -e -i "${default_answer}" -p "${prompt} ${suffix}: " answer
  else
    read -r -p "${prompt} ${suffix}: " answer
  fi
  answer="$(trim "${answer}")"
  if [[ -z "${answer}" ]]; then
    answer="${default_answer}"
  fi

  [[ "${answer}" =~ ^[Yy]$ ]]
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      die "暂不支持当前架构: ${machine}"
      ;;
  esac
}

detect_python() {
  if command_exists python3; then
    echo "python3"
  elif command_exists python; then
    echo "python"
  else
    echo ""
  fi
}

is_valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_valid_ipv6() {
  [[ "$1" == *:* ]]
}

fetch_public_ip() {
  local family="$1"
  local candidate=""
  local -a urls=()

  if [[ "${family}" == "4" ]]; then
    urls=(
      "https://api.ipify.org"
      "https://ipv4.icanhazip.com"
      "https://4.ipw.cn"
    )
  else
    urls=(
      "https://api64.ipify.org"
      "https://ipv6.icanhazip.com"
      "https://6.ipw.cn"
    )
  fi

  for url in "${urls[@]}"; do
    candidate="$(curl "-${family}" -fsS --max-time 5 "${url}" 2>/dev/null || true)"
    candidate="$(trim "${candidate}")"
    if [[ "${family}" == "4" ]] && is_valid_ipv4 "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
    if [[ "${family}" == "6" ]] && is_valid_ipv6 "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  return 1
}

is_public_routable_ip() {
  local family="$1"
  local ip="$2"
  local python_bin
  python_bin="$(detect_python)"

  if [[ -z "${python_bin}" ]]; then
    return 1
  fi

  "${python_bin}" - "${family}" "${ip}" <<'PY'
import ipaddress
import sys

expected_version = 4 if sys.argv[1] == "4" else 6
value = sys.argv[2]

try:
    parsed = ipaddress.ip_address(value)
except ValueError:
    sys.exit(1)

if parsed.version != expected_version or not parsed.is_global:
    sys.exit(1)
PY
}

start_temporary_smtp_probe_server() {
  local family="$1"
  local bind_ip="$2"
  local state_file="$3"
  local python_bin
  python_bin="$(detect_python)"
  [[ -n "${python_bin}" ]] || return 1

  "${python_bin}" - "${family}" "${bind_ip}" "${state_file}" <<'PY' &
import socket
import sys
import time

family = socket.AF_INET if sys.argv[1] == "4" else socket.AF_INET6
host = sys.argv[2]
state_file = sys.argv[3]

def write_state(value):
    with open(state_file, "w", encoding="utf-8") as fh:
        fh.write(value)

sock = socket.socket(family, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if family == socket.AF_INET6:
    try:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    except OSError:
        pass

try:
    bind_target = (host, 25) if family == socket.AF_INET else (host, 25, 0, 0)
    sock.bind(bind_target)
    sock.listen(5)
    sock.settimeout(30)
    write_state("LISTENING")

    peers = []
    deadline = time.time() + 20
    while time.time() < deadline:
        sock.settimeout(max(1.0, deadline - time.time()))
        try:
            conn, addr = sock.accept()
        except socket.timeout:
            break

        peer = addr[0] if isinstance(addr, tuple) else str(addr)
        peers.append(peer)
        conn.settimeout(3)
        try:
            conn.sendall(b"220 mailforge-probe ESMTP ready\r\n")
            try:
                data = conn.recv(1024)
            except Exception:
                data = b""
            if data:
                if data.lstrip().upper().startswith((b"EHLO", b"HELO")):
                    conn.sendall(b"250-mailforge-probe\r\n250 PIPELINING\r\n")
                else:
                    conn.sendall(b"221 mailforge-probe closing connection\r\n")
        except Exception:
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass

        write_state("CONNECTED:" + ",".join(peers))

    if peers:
        sys.exit(0)

    write_state("ERROR:no_external_connection")
    sys.exit(1)
except Exception as exc:
    write_state("ERROR:" + str(exc))
    sys.exit(1)
finally:
    try:
        sock.close()
    except Exception:
        pass
PY

  TEMP_SMTP_PROBE_PID="$!"
  printf '%s' "${TEMP_SMTP_PROBE_PID}"
}

wait_for_probe_server_ready() {
  local pid="$1"
  local state_file="$2"
  local attempt
  local state=""

  for attempt in $(seq 1 10); do
    state="$(cat "${state_file}" 2>/dev/null || true)"
    if [[ "${state}" == "LISTENING" || "${state}" == CONNECTED:* ]]; then
      return 0
    fi
    if [[ "${state}" == ERROR:* ]]; then
      return 1
    fi
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  return 1
}

stop_temporary_smtp_probe_server() {
  local pid="${1:-}"
  if [[ -n "${pid}" ]]; then
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

request_myip_casa_port_check() {
  local host="$1"
  curl -fsSL \
    -A 'Mozilla/5.0 (X11; Linux x86_64) mailforge-installer/1.0' \
    -H 'Accept: application/json' \
    --connect-timeout 10 \
    --retry 2 \
    --retry-delay 2 \
    --max-time 20 \
    --get \
    --data-urlencode "host=${host}" \
    --data "port=25" \
    "https://myip.casa/api/checkport"
}

port_check_result_is_open() {
  [[ "$1" == *'"result":"open"'* ]]
}

check_public_smtp_handshake() {
  local family="$1"
  local ip="$2"
  local python_bin
  python_bin="$(detect_python)"
  [[ -n "${python_bin}" ]] || return 1

  "${python_bin}" - "${family}" "${ip}" <<'PY'
import socket
import sys

family = socket.AF_INET if sys.argv[1] == "4" else socket.AF_INET6
host = sys.argv[2]
address = (host, 25) if family == socket.AF_INET else (host, 25, 0, 0)
sock = socket.socket(family, socket.SOCK_STREAM)
sock.settimeout(6)

try:
    sock.connect(address)
    banner = sock.recv(1024)
    if not banner.startswith(b"220"):
        sys.exit(1)

    sock.sendall(b"EHLO mailforge-installer.local\r\n")
    response = sock.recv(1024)
    if not response.startswith(b"250"):
        sys.exit(1)
except Exception:
    sys.exit(1)
finally:
    sock.close()
PY
}

probe_public_smtp() {
  local family="$1"
  local ip="$2"
  local bind_ip=""
  local probe_dir=""
  local state_file=""
  local pid=""
  local result_json=""
  local state=""
  local attempt
  local external_probe_ok=0
  local local_handshake_ok=0

  is_public_routable_ip "${family}" "${ip}" || return 1

  probe_dir="$(mktemp -d)"
  state_file="${probe_dir}/state"
  bind_ip="0.0.0.0"
  if [[ "${family}" == "6" ]]; then
    bind_ip="::"
  fi

  start_temporary_smtp_probe_server "${family}" "${bind_ip}" "${state_file}" >/dev/null || {
    rm -rf "${probe_dir}"
    return 1
  }
  pid="${TEMP_SMTP_PROBE_PID:-}"
  [[ -n "${pid}" ]] || {
    rm -rf "${probe_dir}"
    return 1
  }

  if ! wait_for_probe_server_ready "${pid}" "${state_file}"; then
    stop_temporary_smtp_probe_server "${pid}"
    rm -rf "${probe_dir}"
    return 1
  fi

  result_json="$(request_myip_casa_port_check "${ip}" || true)"
  if port_check_result_is_open "${result_json}"; then
    external_probe_ok=1
  fi

  if [[ "${family}" == "6" ]] && check_public_smtp_handshake 6 "${ip}"; then
    local_handshake_ok=1
  fi

  for attempt in $(seq 1 10); do
    state="$(cat "${state_file}" 2>/dev/null || true)"
    if [[ "${state}" == CONNECTED:* ]]; then
      if [[ "${family}" == "4" ]] && [[ "${external_probe_ok}" -eq 1 ]]; then
        stop_temporary_smtp_probe_server "${pid}"
        rm -rf "${probe_dir}"
        return 0
      fi
      if [[ "${family}" == "6" ]] && { [[ "${external_probe_ok}" -eq 1 ]] || [[ "${local_handshake_ok}" -eq 1 ]]; }; then
        stop_temporary_smtp_probe_server "${pid}"
        rm -rf "${probe_dir}"
        return 0
      fi
    fi
    sleep 1
  done

  if [[ "${external_probe_ok}" -eq 0 ]]; then
    result_json="$(request_myip_casa_port_check "${ip}" || true)"
    if port_check_result_is_open "${result_json}"; then
      external_probe_ok=1
    fi
  fi
  if [[ "${family}" == "6" ]] && [[ "${local_handshake_ok}" -eq 0 ]] && check_public_smtp_handshake 6 "${ip}"; then
    local_handshake_ok=1
  fi

  for attempt in $(seq 1 3); do
    state="$(cat "${state_file}" 2>/dev/null || true)"
    if [[ "${state}" == CONNECTED:* ]]; then
      if [[ "${family}" == "4" ]] && [[ "${external_probe_ok}" -eq 1 ]]; then
        stop_temporary_smtp_probe_server "${pid}"
        rm -rf "${probe_dir}"
        return 0
      fi
      if [[ "${family}" == "6" ]] && { [[ "${external_probe_ok}" -eq 1 ]] || [[ "${local_handshake_ok}" -eq 1 ]]; }; then
        stop_temporary_smtp_probe_server "${pid}"
        rm -rf "${probe_dir}"
        return 0
      fi
    fi
    sleep 1
  done

  if [[ "${family}" == "6" ]] && [[ "${local_handshake_ok}" -eq 1 ]]; then
    state="$(cat "${state_file}" 2>/dev/null || true)"
    if [[ "${state}" == CONNECTED:* ]]; then
      stop_temporary_smtp_probe_server "${pid}"
      rm -rf "${probe_dir}"
      return 0
    fi
  fi

  stop_temporary_smtp_probe_server "${pid}"
  rm -rf "${probe_dir}"
  return 1
}

extract_port() {
  local addr="$1"
  if [[ "${addr}" =~ :([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

derive_public_base_url_default() {
  local http_addr="$1"
  local port
  port="$(extract_port "${http_addr}")"
  [[ -n "${port}" ]] || port="8080"

  if [[ -n "${DETECTED_IPV6}" ]]; then
    printf 'http://[%s]:%s' "${DETECTED_IPV6}" "${port}"
  elif [[ -n "${DETECTED_IPV4}" ]]; then
    printf 'http://%s:%s' "${DETECTED_IPV4}" "${port}"
  else
    printf 'http://127.0.0.1:%s' "${port}"
  fi
}

derive_local_health_url() {
  local http_addr="$1"
  local host=""
  local port=""

  if [[ "${http_addr}" =~ ^:([0-9]+)$ ]]; then
    printf 'http://127.0.0.1:%s/health' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${http_addr}" =~ ^0\.0\.0\.0:([0-9]+)$ ]]; then
    printf 'http://127.0.0.1:%s/health' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${http_addr}" =~ ^\[::\]:([0-9]+)$ ]]; then
    printf 'http://[::1]:%s/health' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${http_addr}" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
    printf 'http://[%s]:%s/health' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "${http_addr}" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    printf 'http://%s:%s/health' "${host}" "${port}"
    return 0
  fi

  return 1
}

wait_for_health() {
  local url="$1"
  local attempt
  for attempt in $(seq 1 15); do
    if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

escape_toml_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

csv_to_toml_array() {
  local raw="$1"
  local item=""
  local out=()

  raw="${raw//;/,}"
  IFS=',' read -r -a items <<< "${raw}"
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    [[ -n "${item}" ]] || continue
    out+=("\"$(escape_toml_string "${item}")\"")
  done

  if [[ "${#out[@]}" -eq 0 ]]; then
    return 1
  fi

  local joined=""
  local part
  for part in "${out[@]}"; do
    if [[ -n "${joined}" ]]; then
      joined+=", "
    fi
    joined+="${part}"
  done
  printf '%s' "${joined}"
}

first_domain_from_csv() {
  local raw="$1"
  raw="${raw//;/,}"
  IFS=',' read -r -a items <<< "${raw}"
  local item
  for item in "${items[@]}"; do
    item="$(trim "${item}")"
    if [[ -n "${item}" ]]; then
      printf '%s' "${item}"
      return 0
    fi
  done
  return 1
}

write_service_file() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Mailforge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=MAILFORGE_CONFIG_FILE=${CONFIG_PATH}
ExecStart=${BINARY_PATH}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

create_config_file() {
  local smtp_addr="$1"
  local http_addr="$2"
  local db_path="$3"
  local allowed_domains_raw="$4"
  local default_domain="$5"
  local allow_subdomains="$6"
  local random_length="$7"
  local public_base_url="$8"
  local public_ipv4="$9"
  local public_ipv6="${10}"
  local public_mail_host="${11}"
  local dns_url="${12}"
  local dns_password="${13}"
  local dns_account_index="${14}"
  local dns_auto_ensure="${15}"
  local web_username="${16}"
  local web_password="${17}"
  local web_session_secret="${18}"
  local relay_host="${19}"
  local relay_port="${20}"
  local relay_username="${21}"
  local relay_password="${22}"
  local relay_from="${23}"
  local relay_starttls="${24}"
  local allowed_domains_toml

  allowed_domains_toml="$(csv_to_toml_array "${allowed_domains_raw}")" || die "allowed_domains 不能为空。"

  mkdir -p "${INSTALL_DIR}" "${DATA_DIR}"

  cat > "${CONFIG_PATH}" <<EOF
http_addr = "$(escape_toml_string "${http_addr}")"
smtp_addr = "$(escape_toml_string "${smtp_addr}")"
db_path = "$(escape_toml_string "${db_path}")"
allowed_domains = [${allowed_domains_toml}]
default_domain = "$(escape_toml_string "${default_domain}")"
allow_subdomains = ${allow_subdomains}
random_local_length = ${random_length}
public_base_url = "$(escape_toml_string "${public_base_url}")"
public_ipv4 = "$(escape_toml_string "${public_ipv4}")"
public_ipv6 = "$(escape_toml_string "${public_ipv6}")"
public_mail_host = "$(escape_toml_string "${public_mail_host}")"

[smtp_relay]
host = "$(escape_toml_string "${relay_host}")"
port = ${relay_port}
username = "$(escape_toml_string "${relay_username}")"
password = "$(escape_toml_string "${relay_password}")"
from = "$(escape_toml_string "${relay_from}")"
starttls = ${relay_starttls}

[cloudflare]
url = "$(escape_toml_string "${dns_url}")"
password = "$(escape_toml_string "${dns_password}")"
account_index = ${dns_account_index}
auto_ensure = ${dns_auto_ensure}

[web_auth]
username = "$(escape_toml_string "${web_username}")"
password = "$(escape_toml_string "${web_password}")"
session_secret = "$(escape_toml_string "${web_session_secret}")"
EOF
}

download_binary() {
  local arch
  local asset_name
  local download_url=""
  local tmp_file=""
  local curl_args=()

  arch="$(detect_arch)"
  asset_name="mailforge-linux-${arch}"
  download_url="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${asset_name}"

  mkdir -p "${INSTALL_DIR}"
  tmp_file="$(mktemp "${INSTALL_DIR}/mailforge.XXXXXX")"
  curl_args=(-fL --connect-timeout 10 --retry 3 --retry-delay 2 --progress-bar)

  log "正在从 ${GITHUB_REPO} 的 Release ${RELEASE_TAG} 下载 ${asset_name}"
  if ! curl "${curl_args[@]}" -o "${tmp_file}" "${download_url}"; then
    rm -f "${tmp_file}"
    die "下载二进制失败，请检查公开下载地址是否存在: ${download_url}"
  fi

  chmod +x "${tmp_file}"
  mv "${tmp_file}" "${BINARY_PATH}"
}

detect_mail_capability() {
  local raw_ipv4=""
  local raw_ipv6=""
  local ipv4_ok=0
  local ipv6_ok=0

  DETECTED_IPV4=""
  DETECTED_IPV6=""
  DETECTED_SMTP_ADDR=""

  raw_ipv4="$(fetch_public_ip 4 || true)"
  raw_ipv6="$(fetch_public_ip 6 || true)"

  if [[ -n "${raw_ipv4}" ]] && probe_public_smtp 4 "${raw_ipv4}"; then
    DETECTED_IPV4="${raw_ipv4}"
    ipv4_ok=1
    log "IPv4 公网 25 端口邮件可通: ${DETECTED_IPV4}"
  elif [[ -n "${raw_ipv4}" ]]; then
    log "IPv4 公网 25 端口邮件探测未通过，默认留空。"
  else
    log "未检测到可用的 IPv4 公网地址，默认留空。"
  fi

  if [[ -n "${raw_ipv6}" ]] && probe_public_smtp 6 "${raw_ipv6}"; then
    DETECTED_IPV6="${raw_ipv6}"
    ipv6_ok=1
    log "IPv6 公网 25 端口邮件可通: ${DETECTED_IPV6}"
  elif [[ -n "${raw_ipv6}" ]]; then
    log "IPv6 公网 25 端口邮件探测未通过，默认留空。"
  else
    log "未检测到可用的 IPv6 公网地址，默认留空。"
  fi

  if [[ "${ipv4_ok}" -eq 1 && "${ipv6_ok}" -eq 1 ]]; then
    DETECTED_SMTP_ADDR=":25"
  elif [[ "${ipv4_ok}" -eq 1 ]]; then
    DETECTED_SMTP_ADDR="${DETECTED_IPV4}:25"
  elif [[ "${ipv6_ok}" -eq 1 ]]; then
    DETECTED_SMTP_ADDR="[${DETECTED_IPV6}]:25"
  else
    die "未检测到公网且 SMTP 实际可通的 IPv4/IPv6，安装已停止。"
  fi

  log "将默认使用 SMTP 监听地址: ${DETECTED_SMTP_ADDR}"
  pause
}

render_existing_config_summary() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    log "检测到已有配置文件: ${CONFIG_PATH}"
  fi
}

read_existing_http_addr() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return 1
  fi
  sed -n 's/^http_addr[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "${CONFIG_PATH}" | head -n 1
}

prepare_runtime_for_install() {
  local legacy_processes=""
  local legacy_pids=""

  if systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      log "检测到现有 systemd 服务，安装前先停止 ${SERVICE_NAME}。"
      systemctl stop "${SERVICE_NAME}" || true
    fi
  fi

  legacy_processes="$(pgrep -af 'mailforge' | grep -v 'mailforge-installer.sh' || true)"
  if [[ -n "${legacy_processes}" ]]; then
    warn "检测到旧的 mailforge 进程，准备清理旧部署："
    printf '%s\n' "${legacy_processes}"
    if confirm "是否终止这些旧的 mailforge 进程？" "Y"; then
      legacy_pids="$(printf '%s\n' "${legacy_processes}" | awk '{print $1}')"
      if [[ -n "${legacy_pids}" ]]; then
        # 仅按已确认的 PID 精准结束，避免误杀当前安装脚本。
        kill ${legacy_pids} || true
      fi
      sleep 1
    fi
  fi
}

install_mailforge() {
  local skip_config=0
  local http_addr=""
  local smtp_addr=""
  local db_path=""
  local allowed_domains=""
  local default_domain=""
  local allow_subdomains=""
  local random_length=""
  local public_base_url=""
  local public_ipv4=""
  local public_ipv6=""
  local public_mail_host=""
  local dns_url=""
  local dns_password=""
  local dns_account_index=""
  local dns_auto_ensure=""
  local web_username=""
  local web_password=""
  local web_session_secret=""
  local relay_host=""
  local relay_port=""
  local relay_username=""
  local relay_password=""
  local relay_from=""
  local relay_starttls=""
  local health_url=""

  install_curl
  install_python_for_probe
  prepare_runtime_for_install
  detect_mail_capability
  mkdir -p "${INSTALL_DIR}" "${DATA_DIR}"
  download_binary

  render_existing_config_summary
  if [[ -f "${CONFIG_PATH}" ]] && confirm "已有配置文件，是否跳过配置文件生成？" "Y"; then
    skip_config=1
  fi

  if [[ "${skip_config}" -eq 0 ]]; then
    smtp_addr="${DETECTED_SMTP_ADDR}"
    http_addr="$(prompt_with_default "请输入 MAILFORGE_HTTP_ADDR（Web 监听地址）" ":8080")"
    db_path="$(prompt_with_default "请输入 MAILFORGE_DB_PATH（数据库路径）" "${DATA_DIR}/mailforge.db")"

    while true; do
      allowed_domains="$(prompt_with_default "请输入 MAILFORGE_ALLOWED_DOMAINS（多个域名用逗号分隔）" "")"
      allowed_domains="$(trim "${allowed_domains}")"
      if [[ -n "${allowed_domains}" ]]; then
        break
      fi
      warn "allowed_domains 不能为空。"
    done

    default_domain="$(first_domain_from_csv "${allowed_domains}" || true)"
    default_domain="$(prompt_with_default "请输入 MAILFORGE_DEFAULT_DOMAIN（默认域名）" "${default_domain}")"
    allow_subdomains="$(prompt_with_default "请输入 MAILFORGE_ALLOW_SUBDOMAINS（true/false）" "true")"
    random_length="$(prompt_with_default "请输入 MAILFORGE_RANDOM_LENGTH（随机邮箱长度）" "10")"

    public_base_url="$(prompt_with_default "请输入 MAILFORGE_PUBLIC_BASE_URL（对外访问地址）" "$(derive_public_base_url_default "${http_addr}")")"
    public_ipv4="$(prompt_with_default "请输入 MAILFORGE_PUBLIC_IPV4（留空表示不写入）" "${DETECTED_IPV4}")"
    public_ipv6="$(prompt_with_default "请输入 MAILFORGE_PUBLIC_IPV6（留空表示不写入）" "${DETECTED_IPV6}")"
    public_mail_host="$(prompt_with_default "请输入 MAILFORGE_PUBLIC_MAIL_HOST（留空默认 mail.<domain>）" "mail.${default_domain}")"

    dns_url="$(prompt_with_default "请输入 MAILFORGE_DNS_MANAGER_URL（Cloudflare 管理后台地址）" "")"
    dns_password="$(prompt_secret_with_default "请输入 MAILFORGE_DNS_MANAGER_PASSWORD（Cloudflare 管理后台密码）")"
    dns_account_index="$(prompt_with_default "请输入 MAILFORGE_DNS_MANAGER_ACCOUNT_INDEX（0 为自动遍历）" "0")"
    dns_auto_ensure="$(prompt_with_default "请输入 MAILFORGE_DNS_AUTO_ENSURE（true/false）" "true")"

    web_username="$(prompt_with_default "请输入 MAILFORGE_WEB_USERNAME（后台用户名）" "")"
    web_password="$(prompt_secret_with_default "请输入 MAILFORGE_WEB_PASSWORD（后台密码）")"
    web_session_secret="$(prompt_secret_with_default "请输入 MAILFORGE_WEB_SESSION_SECRET（留空自动生成）" "")"

    relay_host="$(prompt_with_default "请输入 MAILFORGE_SMTP_RELAY_HOST（留空表示不使用 relay）" "")"
    relay_port="$(prompt_with_default "请输入 MAILFORGE_SMTP_RELAY_PORT" "587")"
    relay_username="$(prompt_with_default "请输入 MAILFORGE_SMTP_RELAY_USERNAME" "")"
    relay_password="$(prompt_secret_with_default "请输入 MAILFORGE_SMTP_RELAY_PASSWORD" "")"
    relay_from="$(prompt_with_default "请输入 MAILFORGE_SMTP_RELAY_FROM（留空跟随发件人）" "")"
    relay_starttls="$(prompt_with_default "请输入 MAILFORGE_SMTP_RELAY_STARTTLS（true/false）" "true")"

    create_config_file \
      "${smtp_addr}" \
      "${http_addr}" \
      "${db_path}" \
      "${allowed_domains}" \
      "${default_domain}" \
      "${allow_subdomains}" \
      "${random_length}" \
      "${public_base_url}" \
      "${public_ipv4}" \
      "${public_ipv6}" \
      "${public_mail_host}" \
      "${dns_url}" \
      "${dns_password}" \
      "${dns_account_index}" \
      "${dns_auto_ensure}" \
      "${web_username}" \
      "${web_password}" \
      "${web_session_secret}" \
      "${relay_host}" \
      "${relay_port}" \
      "${relay_username}" \
      "${relay_password}" \
      "${relay_from}" \
      "${relay_starttls}"
    log "配置文件已写入 ${CONFIG_PATH}"
  else
    http_addr="$(read_existing_http_addr || true)"
  fi

  write_service_file
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  sleep 2

  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    systemctl --no-pager -l status "${SERVICE_NAME}" || true
    die "mailforge 服务启动失败。"
  fi

  if [[ -z "${http_addr}" ]]; then
    http_addr="$(read_existing_http_addr || true)"
  fi
  health_url="$(derive_local_health_url "${http_addr:-:8080}" || true)"
  if [[ -n "${health_url}" ]]; then
    if wait_for_health "${health_url}"; then
      log "健康检查通过: ${health_url}"
    else
      warn "服务已启动，但健康检查未通过: ${health_url}"
    fi
  fi

  log "mailforge 安装完成。"
}

manage_mailforge() {
  while true; do
    echo
    echo "1. 关闭mailforge"
    echo "2. 重启mailforge"
    echo "3. 查看mailforge状态"
    echo "0. 返回上一级"
    echo
    read -r -p "请选择: " choice
    case "${choice}" in
      1)
        systemctl stop "${SERVICE_NAME}"
        log "mailforge 已关闭。"
        ;;
      2)
        systemctl restart "${SERVICE_NAME}"
        systemctl --no-pager -l status "${SERVICE_NAME}" || true
        ;;
      3)
        systemctl --no-pager -l status "${SERVICE_NAME}" || true
        ;;
      0)
        return 0
        ;;
      *)
        warn "无效选择，请重新输入。"
        ;;
    esac
  done
}

uninstall_mailforge() {
  if ! confirm "确认卸载 mailforge？" "N"; then
    log "已取消卸载。"
    return 0
  fi

  local delete_all=0
  if confirm "是否删除整个安装目录（包含配置文件和数据库）？" "N"; then
    delete_all=1
  fi

  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload

  if [[ "${delete_all}" -eq 1 ]]; then
    rm -rf "${INSTALL_DIR}"
    log "已删除安装目录 ${INSTALL_DIR}"
  else
    rm -f "${BINARY_PATH}"
    log "已删除二进制文件，配置文件和数据已保留。"
  fi
}

main_menu() {
  while true; do
    echo
    echo "1. 安装mailforge"
    echo "2. 管理mailforge"
    echo "3. 卸载mailforge"
    echo "0. 退出"
    echo
    read -r -p "请选择: " choice
    case "${choice}" in
      1)
        install_mailforge
        ;;
      2)
        manage_mailforge
        ;;
      3)
        uninstall_mailforge
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选择，请重新输入。"
        ;;
    esac
  done
}

require_root
require_linux_systemd
main_menu
