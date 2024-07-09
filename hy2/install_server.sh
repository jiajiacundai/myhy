#!/usr/bin/env bash
#
# install_server.sh - hysteria server install script
# Try `install_server.sh --help` for usage.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2023 Aperture Internet Laboratory
#

set -e

###
# SCRIPT CONFIGURATION
###

# Basename of this script
SCRIPT_NAME="$(basename "$0")"

# Command line arguments of this script
SCRIPT_ARGS=("$@")

# Path for installing executable
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"

# Paths to install systemd files
SYSTEMD_SERVICES_DIR="/etc/systemd/system"

# Directory to store hysteria config file
CONFIG_DIR="/etc/hysteria"

# URLs of GitHub
REPO_URL="https://github.com/apernet/hysteria"
API_BASE_URL="https://api.github.com/repos/apernet/hysteria"

# curl command line flags.
# To use a proxy, please specify ALL_PROXY in the environ variable, such like:
# export ALL_PROXY=socks5h://192.0.2.1:1080
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)


###
# AUTO DETECTED GLOBAL VARIABLE
###

# Package manager
PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"

# Operating System of current machine, supported: linux
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"

# Architecture of current machine, supported: 386, amd64, arm, arm64, mipsle, s390x
ARCHITECTURE="${ARCHITECTURE:-}"

# User for running hysteria
HYSTERIA_USER="${HYSTERIA_USER:-}"

# Directory for ACME certificates storage
HYSTERIA_HOME_DIR="${HYSTERIA_HOME_DIR:-}"


###
# ARGUMENTS
###

# Supported operation: install, remove, check_update
OPERATION=

# User specified version to install
VERSION=

# Force install even if installed
FORCE=

# User specified binary to install
LOCAL_FILE=


###
# COMMAND REPLACEMENT & UTILITIES
###

has_command() {
  local _command=$1

  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "/tmp/hyservinst.XXXXXXXXXX"
}

tput() {
  if has_command tput; then
    command tput "$@"
  fi
}

tred() {
  tput setaf 1
}

tgreen() {
  tput setaf 2
}

tyellow() {
  tput setaf 3
}

tblue() {
  tput setaf 4
}

taoi() {
  tput setaf 6
}

tbold() {
  tput bold
}

treset() {
  tput sgr0
}

note() {
  local _msg="$1"

  echo -e "$SCRIPT_NAME: $(tbold)note: $_msg$(treset)"
}

warning() {
  local _msg="$1"

  echo -e "$SCRIPT_NAME: $(tyellow)warning: $_msg$(treset)"
}

error() {
  local _msg="$1"

  echo -e "$SCRIPT_NAME: $(tred)error: $_msg$(treset)"
}

has_prefix() {
    local _s="$1"
    local _prefix="$2"

    if [[ -z "$_prefix" ]]; then
        return 0
    fi

    if [[ -z "$_s" ]]; then
        return 1
    fi

    [[ "x$_s" != "x${_s#"$_prefix"}" ]]
}

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64
}

systemctl() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]] || ! has_command systemctl; then
    warning "Ignored systemd command: systemctl $@"
    return
  fi

  command systemctl "$@"
}

show_argument_error_and_exit() {
  local _error_msg="$1"

  error "$_error_msg"
  echo "Try \"$0 --help\" for usage." >&2
  exit 22
}

install_content() {
  local _install_flags="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"

  local _tmpfile="$(mktemp)"

  echo -ne "Install $_destination ... "
  echo "$_content" > "$_tmpfile"
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "exists"
  elif install "$_install_flags" "$_tmpfile" "$_destination"; then
    echo -e "ok"
  fi

  rm -f "$_tmpfile"
}

remove_file() {
  local _target="$1"

  echo -ne "Remove $_target ... "
  if rm "$_target"; then
    echo -e "ok"
  fi
}

exec_sudo() {
  # exec sudo with configurable environ preserved.
  local _saved_ifs="$IFS"
  IFS=$'\n'
  local _preserved_env=(
    $(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
    $(env | grep "^OPERATING_SYSTEM=" || true)
    $(env | grep "^ARCHITECTURE=" || true)
    $(env | grep "^HYSTERIA_\w*=" || true)
    $(env | grep "^FORCE_\w*=" || true)
  )
  IFS="$_saved_ifs"

  exec sudo env \
    "${_preserved_env[@]}" \
    "$@"
}

detect_package_manager() {
  if [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]]; then
    return 0
  fi

  if has_command apt; then
    PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
    return 0
  fi

  if has_command dnf; then
    PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
    return 0
  fi

  if has_command yum; then
    PACKAGE_MANAGEMENT_INSTALL='yum -y install'
    return 0
  fi

  if has_command zypper; then
    PACKAGE_MANAGEMENT_INSTALL='zypper install -y --no-recommends'
    return 0
  fi

  if has_command pacman; then
    PACKAGE_MANAGEMENT_INSTALL='pacman -Syu --noconfirm'
    return 0
  fi

  return 1
}

install_software() {
  local _package_name="$1"

  if ! detect_package_manager; then
    error "Supported package manager is not detected, please install the following package manually:"
    echo
    echo -e "\t* $_package_name"
    echo
    exit 65
  fi

  echo "Installing missing dependence '$_package_name' with '$PACKAGE_MANAGEMENT_INSTALL' ... "
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then
    echo "ok"
  else
    error "Cannot install '$_package_name' with detected package manager, please install it manually."
    exit 65
  fi
}

is_user_exists() {
  local _user="$1"

  id "$_user" > /dev/null 2>&1
}

rerun_with_sudo() {
  if ! has_command sudo; then
    return 13
  fi

  local _target_script

  if has_prefix "$0" "/dev/fd/"; then
    local _tmp_script="$(mktemp)"
    chmod +x "$_tmp_script"

    if has_command curl; then
      curl -o "$_tmp_script" 'https://get.hy2.sh/'
    elif has_command wget; then
      wget -O "$_tmp_script" 'https://get.hy2.sh'
    else
      return 127
    fi

    _target_script="$_tmp_script"
  else
    _target_script="$0"
  fi

  note "Re-running this script with sudo. You can also specify FORCE_NO_ROOT=1 to force this script to run as the current user."
  exec_sudo "$_target_script" "${SCRIPT_ARGS[@]}"
}

check_permission() {
  if [[ "$UID" -eq '0' ]]; then
    return
  fi

  note "The user running this script is not root."

  case "$FORCE_NO_ROOT" in
    '1')
      warning "FORCE_NO_ROOT=1 detected, we will proceed without root, but you may get insufficient privileges errors."
      ;;
    *)
      if ! rerun_with_sudo; then
        error "Please run this script with root or specify FORCE_NO_ROOT=1 to force this script to run as the current user."
        exit 13
      fi
      ;;
  esac
}

check_environment_operating_system() {
  if [[ -n "$OPERATING_SYSTEM" ]]; then
    warning "OPERATING_SYSTEM=$OPERATING_SYSTEM detected, operating system detection will not be performed."
    return
  fi

  if [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
    return
  fi

  error "This script only supports Linux."
  note "Specify OPERATING_SYSTEM=[linux|darwin|freebsd|windows] to bypass this check and force this script to run on this $(uname)."
  exit 95
}

check_environment_architecture() {
  if [[ -n "$ARCHITECTURE" ]]; then
    warning "ARCHITECTURE=$ARCHITECTURE detected, architecture detection will not be performed."
    return
  fi

  case "$(uname -m)" in
    'i386' | 'i686')
      ARCHITECTURE=386
      ;;
    'x86_64' | 'amd64')
      ARCHITECTURE=amd64
      ;;
    'armv5tel' | 'armv6l')
      ARCHITECTURE=arm
      ;;
    'armv7' | 'armv7l' | 'armv8' | 'aarch64')
      ARCHITECTURE=arm64
      ;;
    'mips' | 'mipsle' | 'mips64' | 'mips64le')
      ARCHITECTURE=mipsle
      ;;
    's390x')
      ARCHITECTURE=s390x
      ;;
    *)
      error "This script only supports x86_64, arm, arm64, mipsle and s390x architectures."
      note "Specify ARCHITECTURE=[386|amd64|arm|arm64|mipsle|s390x] to bypass this check and force this script to run on this $(uname -m)."
      exit 95
      ;;
  esac
}

check_environment_binary() {
  if [[ -z "$LOCAL_FILE" || -r "$LOCAL_FILE" ]]; then
    return
  fi

  error "Cannot read the specified LOCAL_FILE=$LOCAL_FILE."
  exit 96
}

check_environment_version() {
  if [[ "$OPERATION" != 'install' ]]; then
    return
  fi

  if [[ -n "$VERSION" ]]; then
    return
  fi

  note "Detecting the latest version ..."
  local _version
  _version="$(curl -sS "$API_BASE_URL/releases/latest" | sed -n 's/^ *"tag_name": "\(.*\)".*/\1/p')"
  if [[ -z "$_version" ]]; then
    error "Unable to get the latest version."
    exit 97
  fi
  VERSION="$_version"
}

check_environment() {
  if [[ "$OPERATION" == 'check_update' ]]; then
    return
  fi

  check_permission
  check_environment_operating_system
  check_environment_architecture
  check_environment_binary
  check_environment_version
}

systemd_hysteria_service_content() {
  cat <<EOF
[Unit]
Description=Hysteria - The QUIC All-In-One Transport
Documentation=https://github.com/apernet/hysteria
After=network.target

[Service]
User=${HYSTERIA_USER:-root}
ExecStart=${EXECUTABLE_INSTALL_PATH} -c ${CONFIG_DIR}/config.yaml server
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

get_current_version() {
  local _current_version

  _current_version="$(${EXECUTABLE_INSTALL_PATH} --version | awk '{print $2}' 2>/dev/null || true)"
  if [[ -z "$_current_version" ]]; then
    _current_version="$(${EXECUTABLE_INSTALL_PATH} version | awk '{print $3}' 2>/dev/null || true)"
  fi
  if [[ -z "$_current_version" ]]; then
    return 1
  fi

  echo "$_current_version"
}

remove_installed_files() {
  systemctl stop hysteria || true
  systemctl disable hysteria || true

  remove_file "$EXECUTABLE_INSTALL_PATH"

  local _systemd_service
  for _systemd_service in \
    "${SYSTEMD_SERVICES_DIR}/hysteria.service" \
  ; do
    if [[ -f "$_systemd_service" ]]; then
      systemctl disable "$(basename "$_systemd_service")" || true
      remove_file "$_systemd_service"
    fi
  done

  echo -ne "Remove ${CONFIG_DIR} ... "
  rm -rf "${CONFIG_DIR}"
  echo -e "ok"
}

download_binary() {
  local _tempdir
  _tempdir="$(mktemp -d)"

  local _file="${LOCAL_FILE:-}"
  if [[ -z "$_file" ]]; then
    _file="${_tempdir}/hysteria"
    echo "Downloading hysteria ${VERSION} for ${ARCHITECTURE} from ${REPO_URL} ... "
    curl -o "$_file" -L "https://github.com/apernet/hysteria/releases/download/${VERSION}/hysteria-linux-${ARCHITECTURE}"
  fi

  chmod +x "$_file"
  mv "$_file" "${EXECUTABLE_INSTALL_PATH}"
}

install_binary() {
  echo "Installing hysteria server ${VERSION} ..."
  download_binary
  echo "Hysteria server ${VERSION} installed successfully!"
}

install_config_files() {
  mkdir -p "${CONFIG_DIR}"

  local _config_file="${CONFIG_DIR}/config.yaml"
  if [[ ! -f "${_config_file}" ]]; then
    echo "Generating default configuration file at ${_config_file} ..."
    cat <<EOF > "${_config_file}"
listen: :443
cert: /etc/ssl/certs/ssl-cert-snakeoil.pem
key: /etc/ssl/private/ssl-cert-snakeoil.key
obfs: $(generate_random_password)
EOF
  fi
}

install_systemd_files() {
  mkdir -p "${SYSTEMD_SERVICES_DIR}"

  install_content '-m 644' "$(systemd_hysteria_service_content)" "${SYSTEMD_SERVICES_DIR}/hysteria.service"
  systemctl daemon-reload
  systemctl enable hysteria
}

install_hysteria_server() {
  local _current_version

  if _current_version="$(get_current_version)"; then
    if [[ "x$_current_version" == "x$VERSION" && -z "$FORCE" ]]; then
      note "Hysteria server ${VERSION} is already installed."
      exit 0
    fi
  fi

  install_binary
  install_config_files
  install_systemd_files

  echo "Starting hysteria server ..."
  systemctl start hysteria

  echo "Hysteria server installed and started successfully!"
}

check_update() {
  local _current_version
  _current_version="$(get_current_version)" || {
    echo "Hysteria server is not installed."
    exit 1
  }

  check_environment_version

  if [[ "x$_current_version" == "x$VERSION" ]]; then
    echo "Hysteria server is up to date (version ${VERSION})."
  else
    echo "Hysteria server is outdated (current: ${_current_version}, latest: ${VERSION})."
  fi
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -i, --install             Install the Hysteria server
  -r, --remove              Remove the Hysteria server
  -c, --check-update        Check for updates to the Hysteria server
  -v, --version VERSION     Specify the version to install (default: latest)
  -f, --force               Force install even if the current version is up to date
  -l, --local FILE          Install from a local binary file
  -h, --help                Show this help message and exit

Environment variables:
  PACKAGE_MANAGEMENT_INSTALL  Override the package manager install command
  OPERATING_SYSTEM            Specify the operating system (linux)
  ARCHITECTURE                Specify the architecture (386, amd64, arm, arm64, mipsle, s390x)
  HYSTERIA_USER               Specify the user for running hysteria (default: root)
  HYSTERIA_HOME_DIR           Specify the home directory for hysteria (default: /etc/hysteria)
  FORCE_NO_ROOT               Force the script to run as the current user without sudo
  FORCE_NO_SYSTEMD            Force the script to ignore systemd commands (default: false)
EOF
}

parse_arguments() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -i|--install)
        OPERATION="install"
        ;;
      -r|--remove)
        OPERATION="remove"
        ;;
      -c|--check-update)
        OPERATION="check_update"
        ;;
      -v|--version)
        shift
        VERSION="$1"
        ;;
      -f|--force)
        FORCE="1"
        ;;
      -l|--local)
        shift
        LOCAL_FILE="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        show_argument_error_and_exit "Unknown option: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_arguments "$@"

  case "$OPERATION" in
    install)
      check_environment
      install_hysteria_server
      ;;
    remove)
      check_permission
      remove_installed_files
      ;;
    check_update)
      check_update
      ;;
    *)
      show_argument_error_and_exit "No operation specified"
      ;;
  esac
}

main "$@"
