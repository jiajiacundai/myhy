#!/bin/bash

# MySQL 5.5 一键安装脚本 for Debian系统

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "这个脚本必须以root权限运行" 1>&2
   exit 1
fi

# 脚本配置
MYSQL_VERSION="5.5.62"
MYSQL_DOWNLOAD_URL="https://dev.mysql.com/get/Downloads/MySQL-5.5/mysql-${MYSQL_VERSION}.tar.gz"
MYSQL_DATA_DIR="/var/lib/mysql"
MYSQL_ROOT_PASSWORD="123456"

# 更新系统并安装必要的依赖
echo "=== 更新系统并安装依赖 ==="
apt-get update
apt-get install -y build-essential cmake libncurses5-dev bison libssl-dev wget tar gcc g++ make

# 创建mysql用户和组
echo "=== 创建mysql用户和组 ==="
groupadd mysql
useradd -r -g mysql -s /bin/false mysql

# 下载MySQL源码
echo "=== 下载MySQL源码 ==="
mkdir -p /usr/local/src
cd /usr/local/src
wget ${MYSQL_DOWNLOAD_URL} -O mysql-${MYSQL_VERSION}.tar.gz
tar -xzvf mysql-${MYSQL_VERSION}.tar.gz
cd mysql-${MYSQL_VERSION}

# 编译并安装
echo "=== 编译并安装MySQL ==="
cmake . \
-DCMAKE_INSTALL_PREFIX=/usr/local/mysql \
-DMYSQL_DATADIR=${MYSQL_DATA_DIR} \
-DSYSCONFDIR=/etc \
-DWITH_INNOBASE_STORAGE_ENGINE=1 \
-DWITH_ARCHIVE_STORAGE_ENGINE=1 \
-DWITH_BLACKHOLE_STORAGE_ENGINE=1 \
-DWITH_PARTITION_STORAGE_ENGINE=1 \
-DWITH_FEDERATED_STORAGE_ENGINE=1 \
-DDEFAULT_CHARSET=utf8 \
-DDEFAULT_COLLATION=utf8_general_ci

make
make install

# 配置MySQL
echo "=== 配置MySQL ==="
cd /usr/local/mysql
chown -R mysql:mysql .
scripts/mysql_install_db --user=mysql --datadir=${MYSQL_DATA_DIR}

# 配置my.cnf
cat > /etc/my.cnf << EOF
[mysqld]
basedir=/usr/local/mysql
datadir=${MYSQL_DATA_DIR}
port=3306
socket=/tmp/mysql.sock
user=mysql
EOF

# 复制启动脚本
cp support-files/mysql.server /etc/init.d/mysql
chmod +x /etc/init.d/mysql

# 启动MySQL服务
echo "=== 启动MySQL服务 ==="
/etc/init.d/mysql start

# 设置root密码
echo "=== 设置MySQL root密码 ==="
/usr/local/mysql/bin/mysqladmin -u root password "${MYSQL_ROOT_PASSWORD}"

# 配置环境变量
echo "=== 配置MySQL环境变量 ==="
echo "export PATH=\$PATH:/usr/local/mysql/bin" >> /etc/profile
source /etc/profile

# 允许root远程登录（仅供测试，生产环境不推荐）
echo "=== 配置远程登录 ==="
/usr/local/mysql/bin/mysql -u root -p${MYSQL_ROOT_PASSWORD} << EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

echo "=== MySQL 5.5安装完成 ==="
echo "MySQL安装路径: /usr/local/mysql"
echo "MySQL数据目录: ${MYSQL_DATA_DIR}"
echo "MySQL root密码: ${MYSQL_ROOT_PASSWORD}"
echo "请使用 /etc/init.d/mysql {start|stop|restart|status} 管理MySQL服务"

exit 0
