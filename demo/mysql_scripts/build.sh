#!/bin/bash

# mysql源码路径（请替换为实际路径）
mysql_source_path=${MYSQL_SOURCE_PATH:-/path/to/percona-server}
# mysql构建后路径（请替换为实际路径）
mysql_install_path=${MYSQL_INSTALL_PATH:-/path/to/mysql-install}
# boost路径（请替换为实际路径）
boost_path=${BOOST_PATH:-/path/to/boost}

# 如需自定义优化级别，取消注释并设置
#opt_flags="-O3 -march=native"

cd "$mysql_source_path"

if [ -d "gcc_build" ];then
  rm -rf gcc_build
fi

mkdir gcc_build && cd gcc_build

cmake .. -DWITH_BOOST="${boost_path}" \
         -DWITH_COREDUMPER=OFF \
         -DWITH_EMBEDDED_SERVER=OFF \
         -DWITH_UNIT_TESTS=OFF \
         -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         ${opt_flags:+-DCMAKE_CXX_FLAGS_RELEASE="$opt_flags"} \
         ${opt_flags:+-DCMAKE_C_FLAGS="$opt_flags"} \
         ${opt_flags:+-DCMAKE_CXX_FLAGS="$opt_flags"} \
         -DCMAKE_INSTALL_PREFIX="$mysql_install_path" \
         -DWITH_LTO=1

make -j $(nproc) && make install -j $(nproc)