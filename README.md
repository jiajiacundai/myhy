# 自用
# mailforge 一键安装
```shell
curl -fsSL -o mailforge-installer.sh https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/mailforge-installer.sh && chmod +x mailforge-installer.sh && bash mailforge-installer.sh
```

- 安装脚本路径：`debian/mailforge-installer.sh`
- 二进制下载来源：`https://github.com/jiajiacundai/myhy/releases/tag/mailforge-latest`
- 当前脚本会自动从 `mailforge-latest` 下载 `mailforge-linux-amd64` / `mailforge-linux-arm64`

# debian10升级debian11
```shell
wget -O debain_up10_11.sh --no-check-certificate https://iii.sanguoguoguo.free.hr/https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/debain_up10_11.sh && chmod +x debain_up10_11.sh && ./debain_up10_11.sh
```
# debian卸载python2
```shell
curl -s https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/remove_python2.sh | bash
```
# 添加Swap空间
```shell
curl -s https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/addswap.sh | bash -s -- --add
```
# 移除Swap空间
```shell
curl -s https://raw.githubusercontent.com/jiajiacundai/myhy/main/debian/addswap.sh | bash -s -- --remove
```
# unbantu禁用一键脚本
```shell
curl -s https://iii.sanguoguoguo.us.kg/https://raw.githubusercontent.com/jiajiacundai/myhy/main/unbantu/disable_updates.sh | bash
```
# gost一键脚本
```shell
wget -qO gost.sh https://iii.sanguoguoguo.us.kg/https://raw.githubusercontent.com/jiajiacundai/myhy/refs/heads/main/gost/gost.sh && bash gost.sh
```
