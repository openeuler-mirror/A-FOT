#!/bin/bash

# mysql源码路径
mysql_source_path=/path/to/you/mysql
# mysql构建后路径
mysql_install_path=/usr/local/mysql/

opt_flags="-O3 -march=armv8.2-a"

cd $mysql_source_path

if [ -d "gcc_build" ];then
  rm -rf gcc_build
fi

mkdir gcc_build && cd gcc_build

cmake .. -DWITH_BOOST=../boost/boost_1_XX_0/ \
         -DCMAKE_BUILD_TYPE=RelWithDebInfo \
         -DCMAKE_INSTALL_PREFIX="$mysql_install_path" \
         -DCMAKE_CXX_FLAGS_RELEASE="$opt_flags" \
         -DCMAKE_C_FLAGS="$opt_flags" \
         -DCMAKE_CXX_FLAGS="$opt_flags" \
         -DWITH_LTO=1

make -j && make install -j