#!/bin/bash

mysql_install_path=/usr/local/mysql

# 清空所有类型缓存
echo 3 > /proc/sys/vm/drop_caches

# 启动新的mysqld实例
numactl -C 120-127 $mysql_install_path/bin/mysqld --default-file=/etc/my.cnf &
sleep 15

sshpass -p "PASSWD" ssh "CLIENT_IP" "sysbench --db-driver=mysql --mysql-host=HOST_IP --mysql-port=3306 --mysql-user=root --mysql-password=123456 --mysql-db=sbtest --table_size=10000000 --tables=64  --time=180  --threads=32 --report-interval=10 oltp_read_only run"

sshpass -p "PASSWD" ssh "CLIENT_IP" "sysbench --db-driver=mysql --mysql-host=HOST_IP --mysql-port=3306 --mysql-user=root --mysql-password=123456 --mysql-db=sbtest --table_size=10000000 --tables=64  --time=180  --threads=32 --report-interval=10 oltp_write_only run"

sshpass -p "PASSWD" ssh "CLIENT_IP" "sysbench --db-driver=mysql --mysql-host=HOST_IP --mysql-port=3306 --mysql-user=root --mysql-password=123456 --mysql-db=sbtest --table_size=10000000 --tables=64  --time=180  --threads=32 --report-interval=10 oltp_read_write run"

pkill mysqld
