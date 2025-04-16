# 以 Debian 的最新版作为基础镜像
FROM debian:latest

# 更新包列表，并安装 openssh-server、curl 等工具
RUN apt-get update \
    && apt-get install -y openssh-server curl \
    \
    # 为 ssh 服务生成默认密钥，确保 sshd 正常工作
    && ssh-keygen -A \
    \
    # 安装 curl、wget、sudo 和 python（注意部分工具可能已经安装，视使用场景而定）
    && apt-get install -y curl wget sudo python3 kmod \
    \
    # 重写 /usr/bin/reboot 文件，使其在容器内仅仅终止 PID 为 1 的进程（通常是容器的主进程）
    && echo 'kill 1' >> /usr/bin/reboot \
    && chmod +x /usr/bin/reboot \
    \
    # 设置 root 密码（{{ROOT_PASSWORD}} 为模板变量，需要在构建时替换为实际密码）
    && echo 'root:{{ROOT_PASSWORD}}' | chpasswd \
    \
    # 修改 sshd 配置，启用 root 远程登录。首先取消注释 PermitRootLogin 配置
    && sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    \
    # 确保 PermitRootLogin 配置为 yes
    && sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    \
    # 允许空密码登录（不建议在生产环境中使用，仅用于测试）
    && sed -i 's/#PermitEmptyPasswords no/PermitEmptyPasswords yes/' /etc/ssh/sshd_config \
    \
    # 启用密码认证：取消注释 PasswordAuthentication 配置并设置为 yes
    && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    \
    # 添加 ClientAliveInterval 与 ClientAliveCountMax 配置，设置 SSH 客户端连接的存活时间和最大无响应次数
    && echo "ClientAliveInterval 60" >> /etc/ssh/sshd_config \
    && echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config \
    \
    # 创建 /run/sshd 目录，确保 SSH 服务启动时有所依赖的文件夹
    && mkdir /run/sshd

# 暴露 22 端口以便进行 SSH 连接
EXPOSE 22

# 定义容器启动后执行的命令，持续运行 SSH 守护进程，-D 表示不分离后台运行
CMD ["/usr/sbin/sshd", "-D"]
