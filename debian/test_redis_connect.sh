#!/bin/bash

# PHP 测试脚本内容
php_script="<?php
\$redis = new Redis();
\$connected = \$redis->connect('127.0.0.1', 6379);

if (\$connected) {
    \$redis->set('tutorial-name', 'PHP Redis tutorial');
    echo \$redis->get('tutorial-name');
} else {
    echo 'Could not connect to Redis server.';
}
?>"

# 保存 PHP 测试脚本到临时文件
echo "$php_script" > /tmp/test-redis.php

# 执行 PHP 测试脚本并判断结果
echo "Running Redis connectivity test..."
output=$(php /tmp/test-redis.php)

# 判断是否成功连接 Redis
if [[ "$output" == *"PHP Redis tutorial"* ]]; then
    echo "Redis connection successful!"
else
    echo "Redis connection failed. Error: $output"
fi

# 删除 PHP 测试脚本
echo "Cleaning up the test script..."
rm /tmp/test-redis.php
