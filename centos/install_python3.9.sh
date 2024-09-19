#1 依赖安装
#gcc是一个用于linux系统下编程的编译器，由于python3需要编译安装，因此，需要首先安装gcc。先查看一下系统中，是否安装了gcc。
gcc --versions
#发现没有安装，则需要安装。参数-y的作用是在安装过程中自动确认。

yum -y install gcc
#编译安装python3过程中，根据系统本身的依赖，可能出现的不同的报错信息。提前按照好依赖包。

yum -y install zlib*
yum -y install libffi-devel
yum -y install openssl-devel
yum install wget -y
yum install make -y
yum install which -y
#yum update -y 
#yum -y groupinstall "Development tools" 
#yum install openssl-devel bzip2-devel expat-devel gdbm-devel readline-devel sqlite-devel psmisc libffi-devel -y

#2 python3 下载
#在下载前可以检查一下服务器中python的版本，一般linux服务器会自带python2。以下所有操作都是在root账户中进行。

python --version
#当服务器网络较好时，可以直接使用以下命令下载python3的压缩包。下载的版本为python3.9，下载到服务器主目录中（位置可自定义）。

wget https://www.python.org/ftp/python/3.9.6/Python-3.9.6.tgz
#当服务器网络不好时，命令下载花费时间较长，可以考虑在其他机器上先下好压缩包，然后通过工具（MobaXterm,Xshell,...）上传到服务器。

#3 python3编译安装
#解压下载的python3压缩包。

tar -zxvf Python-3.9.6.tgz
#解压后主目录下会多出一个Python-3.9.6文件夹。


#新建一个python3的安装目录(位置可自定义)。

#进入Python-3.9.6目录下，「指定安装目录，设置启用ssl功能」。

cd Python-3.9.6
./configure --enable-shared --with-ssl
#编译安装。

make && make install && make clean
#4 创建软连接
#上述步骤完成后，其实python3已经安装完毕，但是为了方便使用，一般会创建python3和pip3的软连接。创建后可直接在终端通过python命令进入python和pip3命令安装python包。
find / -name libpython3.so
cd /usr/local/lib/
cp libpython3.so libpython3.9.so libpython3.9.so.1.0 /usr/lib64/

#将原来python的软链接重命名：
cp -f /usr/bin/python /usr/bin/python.bak
cp /usr/bin/pip /usr/bin/pip2
rm -rf /usr/bin/pip

#创建python3和pip3软连接：

ln -s /usr/local/bin/pip3 /usr/bin/pip3
ln -s /usr/bin/pip3 /usr/bin/pip
#系统默认的python软连接指向的是python2，如果我们需要更方便使用，可以删除原有的python软连接，并建立新的python软连接指向python3。
ln -s /usr/local/bin/python3 /usr/bin/python3
rm -f /usr/bin/python
ln -s /usr/bin/python3 /usr/bin/python

#查看最新的有python的软连接。

ll /usr/bin/ |grep python

#查看python版本。显示为python 3.9.6。

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
