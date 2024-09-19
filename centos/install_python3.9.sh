#!/bin/bash

# 检查 GCC 版本
gcc --version

# 安装必要的依赖
yum -y install gcc
yum -y install zlib*
yum -y install libffi-devel
yum -y install openssl-devel
yum install wget -y
yum install make -y
yum install which -y

# 检查 Python 版本
python --version

# 下载 Python 3.9.6
wget https://www.python.org/ftp/python/3.9.6/Python-3.9.6.tgz

# 解压下载的文件
tar -zxvf Python-3.9.6.tgz

# 进入 Python 源码目录
cd Python-3.9.6

# 配置编译选项
./configure --enable-shared --with-ssl

# 编译并安装
make && make install && make clean

# 查找 libpython3.so
find / -name libpython3.so

# 复制库文件
cd /usr/local/lib/
cp libpython3.so libpython3.9.so libpython3.9.so.1.0 /usr/lib64/

# 备份原有的 Python 和 pip
cp -f /usr/bin/python /usr/bin/python.bak
cp /usr/bin/pip /usr/bin/pip2
rm -rf /usr/bin/pip

# 创建符号链接
ln -s /usr/local/bin/pip3 /usr/bin/pip3
ln -s /usr/bin/pip3 /usr/bin/pip
ln -s /usr/local/bin/python3 /usr/bin/python3
rm -f /usr/bin/python
ln -s /usr/bin/python3 /usr/bin/python

# 列出 /usr/bin/ 中的 Python 相关文件
ll /usr/bin/ | grep python

# 检查 Python 版本
python --version

# python初始化设置
cat << EOF > up_yum.py
# -*- coding: utf-8 -*-

import os
import subprocess

# 修改文件名
directory = '/usr/bin/'

for filename in os.listdir(directory):
    # if 'yum' in filename:
    if 'yum' == filename or "yum-config-manager" == filename:
        file_path = os.path.join(directory, filename)
        with open(file_path, 'r', encoding="us-ascii") as file:
            lines = file.readlines()
            if len(lines) > 0 and not lines[0].startswith('#!/usr/bin/python2.7'):
                lines[0] = lines[0].replace("python", "python2.7")
                with open(file_path, 'w', encoding="us-ascii") as modified_file:
                    modified_file.writelines(lines)
                print('已修改的文件：{}'.format(filename))

# 修改配置文件
def change_selinux_mode(mode):
    config_file_path = "/etc/selinux/config"
    sed_command = f"sed -i 's/^SELINUX=.*/SELINUX={mode}/' {config_file_path}"
    subprocess.run(sed_command, shell=True, check=True)
    print(f"SELinux mode has been changed to {mode}")

# 将SELinux模式设置为permissive
change_selinux_mode("permissive")

# 修改指定文件的第一行
file_path = '/usr/libexec/urlgrabber-ext-down'

with open(file_path, 'r', encoding="us-ascii") as file:
    lines = file.readlines()

modified = False

if len(lines) > 0 and not lines[0].startswith('#! /usr/bin/python2.7'):
    lines[0] = lines[0].replace("python", "python2.7")
    with open(file_path, 'w', encoding="us-ascii") as modified_file:
        modified_file.writelines(lines)
    modified = True

if modified:
    print('已修改文件：{}'.format(file_path))
else:
    print('文件未被修改：{}'.format(file_path))
EOF
python3 up_yum.py
rm -f up_yum.py
echo "已完成python安装"
