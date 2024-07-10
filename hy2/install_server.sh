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
# To using a proxy, please specify ALL_PROXY in the environ variable, such like:
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
  note "If you want to override this, you can set the OPERATING_SYSTEM environment variable to your operating system."
  exit 86
}

check_environment_architecture() {
  if [[ -n "$ARCHITECTURE" ]]; then
    warning "ARCHITECTURE=$ARCHITECTURE detected, architecture detection will not be performed."
    return
  fi

  case "$(uname -m)" in
    'i386' | 'i686')
      ARCHITECTURE=386
      return
      ;;
    'x86_64')
      ARCHITECTURE=amd64
      return
      ;;
    'armv5tel' | 'armv6l')
      ARCHITECTURE=arm
      return
      ;;
    'armv7' | 'armv7l')
      ARCHITECTURE=arm
      return
      ;;
    'armv8' | 'aarch64')
      ARCHITECTURE=arm64
      return
      ;;
    'mipsle' | 'mips64le')
      ARCHITECTURE=mipsle
      return
      ;;
    's390x')
      ARCHITECTURE=s390x
      return
      ;;
  esac

  error "Architecture $(uname -m) is not supported."
  note "If you want to override this, you can set the ARCHITECTURE environment variable to your architecture."
  exit 87
}

check_environment_hysteria_user() {
  if [[ -n "$HYSTERIA_USER" ]]; then
    warning "HYSTERIA_USER=$HYSTERIA_USER detected, hysteria user detection will not be performed."
    return
  fi

  HYSTERIA_USER=hysteria
}

check_environment_hysteria_home_dir() {
  if [[ -n "$HYSTERIA_HOME_DIR" ]]; then
    warning "HYSTERIA_HOME_DIR=$HYSTERIA_HOME_DIR detected, hysteria home directory detection will not be performed."
    return
  fi

  HYSTERIA_HOME_DIR="/var/lib/hysteria"
}

usage() {
  echo "Usage: $SCRIPT_NAME <operation> [options...]"
  echo
  echo "operations:"
  echo "  install       Install or update hysteria"
  echo "  remove        Remove installed hysteria"
  echo "  check_update  Check the latest hysteria release"
  echo
  echo "options:"
  echo "  --force                 Force install even if installed"
  echo "  --version <version>     Specify version to install"
  echo "  --file <file>           Specify local file to install"
  echo
  echo "example:"
  echo "  $SCRIPT_NAME install"
  echo "  $SCRIPT_NAME install --version v1.3.1"
  echo "  $SCRIPT_NAME remove"
  echo
  echo "environment:"
  echo "  PACKAGE_MANAGEMENT_INSTALL"
  echo "      Package install command."
  echo "  OPERATING_SYSTEM"
  echo "      Override the auto-detected operating system, supported: linux."
  echo "  ARCHITECTURE"
  echo "      Override the auto-detected architecture, supported: 386, amd64, arm, arm64, mipsle, s390x."
  echo "  FORCE_NO_ROOT"
  echo "      Force the script to run without root privileges."
  echo "  HYSTERIA_USER"
  echo "      Specify hysteria user, default: hysteria."
  echo "  HYSTERIA_HOME_DIR"
  echo "      Specify hysteria home directory, default: /var/lib/hysteria."
}

detect_latest_version() {
  if [[ -n "$VERSION" ]]; then
    warning "VERSION=$VERSION detected, latest version detection will not be performed."
    return
  fi

  echo -n "Fetching latest release... "
  local _releases_json
  _releases_json=$(curl "$API_BASE_URL/releases/latest")

  if ! VERSION=$(echo "$_releases_json" | grep -oP '(?<="tag_name": "v)[^"]+'); then
    error "Failed to fetch latest release"
    exit 1
  fi

  VERSION="v$VERSION"
  echo "$VERSION"
}

fetch_release_binary() {
  local _destination="$1"
  local _version="${2:-$VERSION}"

  local _url="$REPO_URL/releases/download/$_version/hysteria-linux-$ARCHITECTURE"
  echo "Fetching hysteria binary from $_url"
  curl -o "$_destination" "$_url"
  chmod +x "$_destination"
}

do_install() {
  check_permission
  check_environment_operating_system
  check_environment_architecture
  check_environment_hysteria_user
  check_environment_hysteria_home_dir

  detect_latest_version

  if [[ -z "$LOCAL_FILE" ]]; then
    local _tmpfile
    _tmpfile=$(mktemp)
    fetch_release_binary "$_tmpfile"
    install -D "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"
    rm "$_tmpfile"
  else
    install -D "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH"
  fi

  if ! is_user_exists "$HYSTERIA_USER"; then
    useradd -r -d "$HYSTERIA_HOME_DIR" -s /sbin/nologin "$HYSTERIA_USER"
  fi

  mkdir -p "$CONFIG_DIR"
  chown "$HYSTERIA_USER:$HYSTERIA_USER" "$CONFIG_DIR"

  install_content '-m 644' "$(systemd_unit_content)" "$SYSTEMD_SERVICES_DIR/hysteria.service"
  systemctl daemon-reload
  systemctl enable hysteria
  systemctl start hysteria
}

do_remove() {
  check_permission

  systemctl stop hysteria
  systemctl disable hysteria
  systemctl daemon-reload

  remove_file "$EXECUTABLE_INSTALL_PATH"
  remove_file "$SYSTEMD_SERVICES_DIR/hysteria.service"
  userdel -r "$HYSTERIA_USER"
}

do_check_update() {
  detect_latest_version
  echo "The latest release of hysteria is $VERSION"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install | remove | check_update)
        OPERATION="$1"
        ;;
      --version)
        shift
        VERSION="$1"
        ;;
      --force)
        FORCE=1
        ;;
      --file)
        shift
        LOCAL_FILE="$1"
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        show_argument_error_and_exit "Unknown argument: $1"
        ;;
    esac
    shift
  done

  if [[ -z "$OPERATION" ]]; then
    show_argument_error_and_exit "Operation is not specified"
  fi

  case "$OPERATION" in
    install)
      do_install
      ;;
    remove)
      do_remove
      ;;
    check_update)
      do_check_update
      ;;
    *)
      show_argument_error_and_exit "Unknown operation: $OPERATION"
      ;;
  esac
}

main "$@"
