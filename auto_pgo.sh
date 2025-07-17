#!/bin/bash

# profdata名字
profdata_name="default.profdata"

# 检测依赖软件是否已经安装
function check_dependency() {
  check_common_dependency
  if [ "$compiler" = "llvm" ]; then
    if ! type llvm-profdata &>/dev/null; then
      echo "[ERROR] Optimization mode ${opt_mode} but llvm-profdata is missing, try 'yum install llvm-profdata'."
      exit 1
    fi
  fi
}

# 根据模式选择Wrapper或者Bear模式构建
function prepare_env() {
  case ${build_mode} in
  "Wrapper")
    create_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-g"
    export LINK_OPTIONS="-g"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear"
    exit 1
    ;;
  esac
}

# 创建原始wrapper
function create_wrapper() {
  echo "[INFO] Start generating the original wrapper."
  echo "${compiler_path}/bin/${c_compiler} -g \"\$@\"" >${compiler_wrapper}/${c_compiler}
  echo "${compiler_path}/bin/${cxx_compiler} -g \"\$@\"" >${compiler_wrapper}/${cxx_compiler}
  post_create_wrapper
}

# 生成profile文件
function profiling () {
  echo "[INFO] Start generating a profile file for auto_pgo."
  prepare_instrument_env
  # 等待原始版本程序执行完成
  wait ${application_pid}
  rm ${bin_file}
  # 生成插桩版本程序
  echo "[INFO] Start generating a instrumented version file for auto_pgo."
  $bear_prefix /bin/bash ${build_script} >>${log_file} 2>&1
  is_file_exist ${bin_file}
  split_option instrumented
  # 运行插桩版本程序得到profile数据
  is_file_exist ${run_script} "run_script"
  echo "[INFO] Start executing the instrumented version file."
  /bin/bash ${run_script} >>${log_file} 2>&1
  # 处理profile数据
  process_profile
  rm ${bin_file}
}

# 处理profile数据
function process_profile() {
  if [ "$compiler" = "llvm" ]; then
    llvm-profdata merge ${profile_data_path}/**/*.profraw -output=${profile_data_path}/${profdata_name}  >>${log_file} 2>&1
    is_file_exist "${profile_data_path}/${profdata_name}"
    count=0
    for dir in "${profile_data_path}"/pgo-*; do
      if [ -d "$dir" ]; then
        if [ $count -eq 0 ]; then
          pgo_dir=$(ls -d ${profile_data_path}/pgo-*/ | head -n 1)
          file_name=$(basename "${pgo_dir}"/*)
          cp "${pgo_dir}/${file_name}" "${profile_data_path}/${file_name}"
        else
          gcov-tool merge -o "${profile_data_path}" "${dir}" "${profile_data_path}"
        fi
        count=$((count + 1))
      fi
    done
    is_file_exist "${profile_data_path}/${file_name}"
  fi
}

# 根据模式选择Wrapper或者Bear模式构建插桩时的环境
function prepare_instrument_env() {
  case ${build_mode} in
  "Wrapper")
    create_instrument_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-fprofile-generate=${profile_data_path}/pgo-%p"
    export LINK_OPTIONS="-fprofile-generate=${profile_data_path}/pgo-%p"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear"
    exit 1
    ;;
  esac
}

# 根据模式选择Wrapper或者Bear模式构建
function prepare_new_env() {
  case ${build_mode} in
  "Wrapper")
    create_new_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-fprofile-use=${profile_data_path}/"
    export LINK_OPTIONS="-fprofile-use=${profile_data_path}/"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear."
    exit 1
    ;;
  esac
}

# 生成插桩时的wrapper
function create_instrument_wrapper() {
  echo "${compiler_path}/bin/${c_compiler}  -fprofile-generate=${profile_data_path}/pgo-%p \"\$@\"" >${compiler_wrapper}/${c_compiler}
  echo "${compiler_path}/bin/${cxx_compiler} -fprofile-generate=${profile_data_path}/pgo-%p\"\$@\"" >${compiler_wrapper}/${cxx_compiler}
}

# 生成新的wrapper
function create_new_wrapper() {
  echo "[INFO] Start to generate a new wrapper."
  echo "${compiler_path}/bin/${c_compiler} -fprofile-use=${profile_data_path}/ \"\$@\"" >${compiler_wrapper}/${c_compiler}
  echo "${compiler_path}/bin/${cxx_compiler} -fprofile-use=${profile_data_path}/ \"\$@\"" >${compiler_wrapper}/${cxx_compiler}
}
