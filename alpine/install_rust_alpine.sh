#!/bin/sh
# alpine一键安装rust脚本

# 一键安装 Rust on Alpine Linux
set -e

echo "🚀 开始安装 Rust 及必要依赖..."

# 1. 更新系统并安装依赖
apk update
apk add --no-cache curl build-base git cmake musl-dev

# 2. 通过官方 rustup 安装 Rust（静默模式）
echo "📦 正在安装 Rust 工具链..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable

# 3. 配置环境变量
source "$HOME/.cargo/env"

# 4. 添加 musl 目标支持（Alpine 必需）
echo "🔧 配置 musl 目标..."
rustup target add x86_64-unknown-linux-musl

# 5. 验证安装
echo "✅ 安装完成！版本信息："
rustc --version
cargo --version

echo "💡 提示：重启终端或运行 'source \$HOME/.cargo/env' 应用环境变量"
