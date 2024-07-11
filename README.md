# 自用
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
