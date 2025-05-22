#!/bin/bash

# 检测依赖软件是否已经安装
# 1. 检查基础依赖
# 2. 验证编译器是否为GCC
# 3. 验证GCC是否支持-fcfgo-profile-generate选项
function check_dependency() {
  # 检查基础依赖
  check_common_dependency
  
  # CFGO only supports GCC compiler
  if [ "$compiler" != "gcc" ]; then
    echo "[ERROR] Optimization mode ${opt_mode} only supports GCC compiler" >&2
    exit 1
  fi
  
  # 检查GCC是否支持-fcfgo-profile-generate选项
  if ! ${compiler_path}/bin/${c_compiler} -fcfgo-profile-generate -E -x c /dev/null >/dev/null 2>&1; then
    echo "[ERROR] GCC compiler does not support -fcfgo-profile-generate option" >&2
    exit 1
  fi

  # 检查llvm-bolt命令是否存在
  if [ ! -f "${compiler_path}/bin/llvm-bolt" ]; then
    echo "[ERROR] llvm-bolt not found in ${compiler_path}/bin/" >&2
    exit 1
  fi
  
  # 检查llvm-bolt是否支持-Om选项
  if ! ${compiler_path}/bin/llvm-bolt --help | grep -q -- "-Om"; then
    echo "[ERROR] llvm-bolt does not support -Om option" >&2
    exit 1
  fi
}

# CFGO-PGO环境准备
function prepare_env() {
  echo "[INFO] Start CFGO-PGO processing"
  case ${build_mode} in
  "Wrapper")
    create_cfgo_pgo_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-fcfgo-profile-generate=${profile_data_path}/cfgo-pgo"
    export LINK_OPTIONS="-fcfgo-profile-generate=${profile_data_path}/cfgo-pgo"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear"
    exit 1
    ;;
  esac
}

# 等待应用程序执行完成并检查状态，然后运行CFGO插桩版本
function profiling() {
  # 检查run_script_pid是否存在
  if [[ -z "${run_script_pid}" ]]; then
      echo "[ERROR] run_script_pid not found, please check run_script" >&2
      exit 1
  fi

  echo "[INFO] Waiting for run_script (PID: ${run_script_pid}) to complete..."
  
  # 等待进程完成并捕获退出状态
  if ! wait "${run_script_pid}"; then
      local exit_status=$?
      echo "[ERROR] run_script exited abnormally with status: ${exit_status}" >&2
      exit "${exit_status}"
  fi

  echo "[INFO] run_script execute successfully"
}

# CFGO-CSPGO插桩
function prepare_new_env() {
  echo "[INFO] Start CFGO-CSPGO processing"
  case ${build_mode} in
  "Wrapper")
    create_cfgo_cspgo_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-fcfgo-profile-use=${profile_data_path}/cfgo-pgo -fcfgo-csprofile-generate=${profile_data_path}/cfgo-cspgo -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction"
    export LINK_OPTIONS="-fcfgo-profile-use=${profile_data_path}/cfgo-pgo -fcfgo-csprofile-generate=${profile_data_path}/cfgo-cspgo -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear."
    exit 1
    ;;
  esac
}

# CFGO-CSPGO插桩
function prepare_bolt_env() {
  echo "[INFO] Start CFGO-BOLT processing"
  case ${build_mode} in
  "Wrapper")
    create_bolt_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="-fcfgo-profile-use=${profile_data_path}/cfgo-pgo \
     -fcfgo-csprofile-use=${profile_data_path}/cfgo-cspgo -Wl,-q \
     -Wno-error=missing-profile -Wno-error=coverage-mismatch \
     -fprofile-correction"
    export LINK_OPTIONS="-fcfgo-profile-use=${profile_data_path}/cfgo-pgo \
      -fcfgo-csprofile-use=${profile_data_path}/cfgo-cspgo -Wl,-q \
      -Wno-error=missing-profile -Wno-error=coverage-mismatch \
      -fprofile-correction"
    ;;
  *)
    echo "[ERROR] Build mode ${build_mode} is not supported, the value is : Wrapper/Bear."
    exit 1
    ;;
  esac
}

# 生成CFGO-PGO插桩的wrapper
function create_cfgo_pgo_wrapper() {
  echo "${compiler_path}/bin/${c_compiler} -fcfgo-profile-generate=${profile_data_path}/cfgo-pgo \"\$@\"" >${compiler_wrapper}/${c_compiler}
  echo "${compiler_path}/bin/${cxx_compiler} -fcfgo-profile-generate=${profile_data_path}/cfgo-pgo \"\$@\"" >${compiler_wrapper}/${cxx_compiler}
  post_create_wrapper
}

# 生成CFGO-CSPGO插桩的wrapper
function create_cfgo_cspgo_wrapper() {
  echo "${compiler_path}/bin/${c_compiler}   -fcfgo-profile-use=${profile_data_path}/cfgo-pgo -fcfgo-csprofile-generate=${profile_data_path}/cfgo-cspgo -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction \"\$@\"" >${compiler_wrapper}/${c_compiler}
  echo "${compiler_path}/bin/${cxx_compiler} -fcfgo-profile-use=${profile_data_path}/cfgo-pgo -fcfgo-csprofile-generate=${profile_data_path}/cfgo-cspgo -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction \"\$@\"" >${compiler_wrapper}/${cxx_compiler}
  post_create_wrapper
}

# 生成CFGO-BOLT插桩的wrapper
function create_bolt_wrapper() {
  echo "${compiler_path}/bin/${c_compiler}   -fcfgo-profile-use=${profile_data_path}/cfgo-pgo -fcfgo-csprofile-use=${profile_data_path}/cfgo-cspgo -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction -Wl,-q \"\$@\"" >${compiler_wrapper}/${c_compiler}
  echo "${compiler_path}/bin/${cxx_compiler} -fcfgo-profile-use=${profile_data_path}/cfgo-pgo -fcfgo-csprofile-use=${profile_data_path}/cfgo-cspgo -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction -Wl,-q \"\$@\"" >${compiler_wrapper}/${cxx_compiler}
  post_create_wrapper
}

function do_bolt_instrument() {
  # 确认BOLT存在
  is_file_exist "${compiler_path}/bin/llvm-bolt"

  # 创建bolt profile dir
  mkdir -p "${profile_data_path}/cfgo-bolt/"

  # 构建命令参数数组
  local bolt_cmd=(
    "${compiler_path}/bin/llvm-bolt"
    --instrument "${bin_file}"
    -o "${bin_file}.inst.bolt"
    -instrumentation-file="${profile_data_path}/cfgo-bolt/bolt.inst.fdata"
    --instrumentation-wait-forks
    --instrumentation-sleep-time=2
    --instrumentation-no-counters-clear
  )

  # 输出命令到日志(带时间戳和分隔符)
  {
    printf '\n# [%s] Executing BOLT instrumentation command:\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf '%q ' "${bolt_cmd[@]}"
    printf '\n\n# Command output:\n'
  } >> "${log_file}"

  # 执行命令并捕获输出
  if ! "${bolt_cmd[@]}" >> "${log_file}" 2>&1; then
    echo "[Error]: BOLT instrumentation failed" >&2
    return 1
  fi

  # 确认插桩后的文件是否存在
  is_file_exist "${bin_file}.inst.bolt"

  # 备份原来的文件
  mv "${bin_file}" "${bin_file}.orig"

  # 将插桩后的文件移动至源文件
  mv ${bin_file}.inst.bolt ${bin_file}

  echo "[INFO] BOLT instrumented success!"
}

function do_bolt_opt() {
  # 确认BOLT profile文件是否存在
  is_file_exist ${profile_data_path}/cfgo-bolt/bolt.inst.fdata

  # 确认BOLT orig文件是否存在
  is_file_exist ${bin_file}.orig

  # 备份BOLT插桩文件
  mv ${bin_file} ${bin_file}.inst.bolt

  # 构建BOLT优化命令数组
  local bolt_opt_cmd=(
    "${compiler_path}/bin/llvm-bolt"
    "${bin_file}.orig"
    -o "${bin_file}"
    -data="${profile_data_path}/cfgo-bolt/bolt.inst.fdata"
    -dyno-stats
    -Om
  )

  # 输出命令到日志(带时间戳和分隔符)
  {
    printf '\n# [%s] Executing BOLT optimization command:\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf '%q ' "${bolt_opt_cmd[@]}"
    printf '\n\n# Command output:\n'
  } >> "${log_file}"

  # 执行优化命令并捕获输出
  if ! "${bolt_opt_cmd[@]}" >> "${log_file}" 2>&1; then
    echo "[Error] BOLT optimization failed" >&2
    return 1
  fi

  # 确认优化后的文件是否存在
  is_file_exist ${bin_file}

  echo "[INFO] BOLT optimization success!"
}
