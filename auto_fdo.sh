#!/bin/bash

# 检测依赖软件是否已经安装
function check_dependency() {
  check_common_dependency
  if ! type create_gcov &>/dev/null; then
    echo "[ERROR] Optimization mode ${opt_mode} but autofdo is missing, try 'yum install autofdo'"
    exit 1
  fi
}

# 创建原始wrapper
function create_wrapper() {
  echo "[INFO] Start generating the original wrapper"
  echo "${gcc_path}/bin/gcc -g \"\$@\"" >${gcc_wrapper}/gcc
  echo "${gcc_path}/bin/g++ -g \"\$@\"" >${gcc_wrapper}/g++
  post_create_wrapper
}

# 执行perf采样，生成profile文件
function perf_record() {
  echo "[INFO] Start perf record by ${opt_mode} and generate a profile file"
  process_id=$(pidof ${application_name})
  get_arch=`arch`
  if [[ ${get_arch} =~ "x86_64" ]];then
    perf_event="br_inst_retired.near_taken:u"
    use_lbr=1
  elif [[ ${get_arch} =~ "aarch64" ]];then
    perf_event="inst_retired:u"
    use_lbr=0
  else
    echo "[ERROR] Unsupport arch: ${get_arch}"
    exit 1
  fi
  perf record -e ${perf_event} -o ${profile_data_path}/${profile_name} -p ${process_id} -- sleep ${perf_time} >> ${log_file} 2>&1
  is_file_exist "${profile_data_path}/${profile_name}"
  create_gcov --binary=${bin_file} --profile=${profile_data_path}/${profile_name} --gcov=${profile_data_path}/${gcov_name} --gcov_version=1 --use_lbr=${use_lbr} >> ${log_file} 2>&1
  is_file_exist "${profile_data_path}/${gcov_name}"
  pkill ${application_name}
}

#生成新的wrapper
function create_new_wrapper() {
  echo "[INFO] Start to generate a new wrapper"
  echo "${gcc_path}/bin/gcc -fauto-profile=${profile_data_path}/${gcov_name} \"\$@\"" >${gcc_wrapper}/gcc
  echo "${gcc_path}/bin/g++ -fauto-profile=${profile_data_path}/${gcov_name} \"\$@\"" >${gcc_wrapper}/g++
}
