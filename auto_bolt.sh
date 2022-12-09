#!/bin/bash

# 检测依赖软件是否已经安装
function check_dependency() {
  check_common_dependency
  if ! type llvm-bolt &>/dev/null; then
    echo "[ERROR] Optimization mode ${opt_mode} but llvm-bolt is missing, try 'yum install llvm-bolt'"
    exit 1
  fi
}

# 根据模式选择Wrapper或者Bear模式构建
function  prepare_env() {
  case ${build_mode} in
  "Wrapper")
    create_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-Wl,-q"
    export LINK_OPTIONS="-q"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear"
    exit 1
    ;;
  esac
}


# 创建原始wrapper
function create_wrapper() {
  echo "[INFO] Start generating the original wrapper"
  echo "${gcc_path}/bin/gcc -Wl,-q \"\$@\"" >${gcc_wrapper}/gcc
  echo "${gcc_path}/bin/g++ -Wl,-q \"\$@\"" >${gcc_wrapper}/g++
  post_create_wrapper
}

# 执行perf采样，生成profile文件
function perf_record() {
  echo "[INFO] Start perf record by ${opt_mode} and generate a profile file"
  process_id=$(pidof ${application_name})
  perf record -e cycles:u -o ${profile_data_path}/${profile_name} -p ${process_id} -- sleep ${perf_time} >> ${log_file} 2>&1
  is_file_exist "${profile_data_path}/${profile_name}"
  perf2bolt -p=${profile_data_path}/${profile_name} ${bin_file} -o ${profile_data_path}/${gcov_name} -nl >> ${log_file} 2>&1
  is_file_exist "${profile_data_path}/${gcov_name}"
  pkill ${application_name}
}


# 根据模式选择Wrapper或者Bear模式构建
function  prepare_new_env() {
  case ${build_mode} in
  "Wrapper")
    create_new_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-fbolt-use=${profile_data_path}/${gcov_name} -fbolt-target=${bin_file} -Wl,-q"
    export LINK_OPTIONS="-q"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear"
    exit 1
    ;;
  esac
}


#生成新的wrapper
function create_new_wrapper() {
  echo "[INFO] Start to generate a new wrapper"
  echo "${gcc_path}/bin/gcc -fbolt-use=${profile_data_path}/${gcov_name} -fbolt-target=${bin_file} -Wl,-q \"\$@\"" >${gcc_wrapper}/gcc
  echo "${gcc_path}/bin/g++ -fbolt-use=${profile_data_path}/${gcov_name} -fbolt-target=${bin_file} -Wl,-q \"\$@\"" >${gcc_wrapper}/g++
}
