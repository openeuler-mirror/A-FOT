#!/bin/bash

# mysql源码路径
mysql_source_path=/home/workspace/percona-server-Percona-Server-5.7.44-53
# mysql构建后路径
mysql_install_path=/home/workspace/mysql-cfgo/

#opt_flags="-O3 -march=armv8.2-a"

cd $mysql_source_path

if [ -d "gcc_build" ];then
  rm -rf gcc_build
fi

mkdir gcc_build && cd gcc_build

cmake .. -DWITH_BOOST=/data/workspace/boost_1_59_0/ \
         -DWITH_COREDUMPER=OFF \
         -DWITH_EMBEDDED_SERVER=OFF \
         -DWITH_UNIT_TESTS=OFF \
         -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         -DCMAKE_CXX_FLAGS_RELEASE="$opt_flags" \
         -DCMAKE_C_FLAGS="$opt_flags" \
         -DCMAKE_CXX_FLAGS="$opt_flags" \
         -DCMAKE_INSTALL_PREFIX="$mysql_install_path" \
         -DWITH_LTO=1

make -j $(nproc) && make install -j  $(nproc)
