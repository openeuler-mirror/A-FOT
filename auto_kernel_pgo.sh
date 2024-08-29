#!/bin/bash

parallel=$(cat /proc/cpuinfo | grep "processor" | wc -l)

# 取消A-FOT脚本的自动执行
cancel_afot_rc() {
  sed -i '/a-fot/d' /etc/rc.d/rc.local
}

# 检查所有配置项
function check_config_items() {
  check_item ${pgo_phase} pgo_phase
  if [[ ${pgo_phase} -ne 1 ]] && [[ ${pgo_phase} -ne 2 ]]; then
    echo "[ERROR] The value of configuration item 'pgo_phase' is invalid, please check!" | tee -a ${log_file}
    exit 1
  fi
  if [[ ${pgo_phase} -eq 1 ]]; then
    check_item ${pgo_mode} pgo_mode
    if [[ ${pgo_mode} != "arc" ]] && [[ ${pgo_mode} != "all" ]]; then
      echo "[ERROR] The value of configuration item 'pgo_mode' is invalid, please check!" | tee -a ${log_file}
      exit 1
    fi
  fi

  check_item ${kernel_name} kernel_name
  check_item ${work_path} work_path
  if [[ ${work_path} =~ "/tmp" ]]; then
    echo "[ERROR] Do not put work path under /tmp, or it will be cleaned after rebooting." | tee -a ${log_file}
    exit 1
  fi
  check_item ${run_script} run_script
  check_item ${compiler_path} compiler_path

  if [[ -n ${disable_compilation} ]]; then
    check_item ${makefile} makefile
    is_file_exist ${makefile} "makefile"
    if [[ ${pgo_phase} -eq 1 ]]; then
      check_item ${kernel_config} kernel_config
      is_file_exist ${kernel_config} "kernel_config"
    fi
    if [[ ${pgo_phase} -eq 2 ]]; then
      check_item ${data_dir} data_dir
      if [[ ! -d ${data_dir} ]]; then
        echo "[ERROR] GCOV data directory ${data_dir} does not exist." | tee -a ${log_file}
        exit 1
      fi
    fi
  fi
}

# 初始化文件和目录
function init() {
  if [[ -z ${last_time} ]] || [[ ${pgo_phase} -eq 1 ]]; then
    now_time=$(date '+%Y%m%d-%H%M%S')
  else
    now_time=${last_time}
  fi
  time_dir=${work_path}/${now_time}
  log_file=${time_dir}/log

  if [[ -d ${time_dir} ]]; then
    echo "[INFO] Use last time directory: ${time_dir}" | tee -a ${log_file}
  else
    mkdir -p ${time_dir}
    echo "[INFO] Create time directory: ${time_dir}" | tee -a ${log_file}
  fi

  if [[ -f ${log_file} ]]; then
    echo "[INFO] Use last log: ${log_file}" | tee -a ${log_file}
  else
    touch ${log_file}
    echo "[INFO] Init log file: ${log_file}" | tee -a ${log_file}
  fi
}

# 检测环境
function check_dependency() {
  get_arch=$(arch)
  if [[ ${get_arch} =~ "x86_64" || ${get_arch} =~ "aarch64" ]]; then
    echo "[INFO] Current arch: ${get_arch}" | tee -a ${log_file}
  else
    echo "[ERROR] Unsupport arch: ${get_arch}" | tee -a ${log_file}
    exit 1
  fi
  is_file_exist ${run_script} "run_script"
  is_file_exist "${compiler_path}/bin/gcc" "compiler_path"

  export CC=${compiler_path}/bin/${c_compiler}
  export PATH=${compiler_path}/bin:${PATH}
  export LD_LIBRARY_PATH=${compiler_path}/lib64:${LD_LIBRARY_PATH}

  if [[ ${pgo_phase} -eq 1 ]] && [[ ${pgo_mode} == "all" ]] && [[ -z ${disable_compilation} ]]; then
    if echo 'int main() { return 0; }' | gcc -x c - -o /dev/null -Werror -fkernel-pgo >/dev/null 2>&1; then
      echo "[INFO] Current GCC supports kernel PGO in runtime, use -fkernel-pgo option." | tee -a ${log_file}
      option="-fkernel-pgo"
    elif gcc -v 2>&1 | grep -- "--disable-tls" >/dev/null; then
      echo "[INFO] Current GCC is recompiled with --disable-tls, does support kernel PGO in runtime." | tee -a ${log_file}
    else
      echo "[ERROR] Current GCC does not support kernel PGO, you may use openeuler GCC or recompile GCC with --disable-tls --disable-libsanitizer." | tee -a ${log_file}
    fi
  fi
}

# 修改内核配置文件
function modify_kernel_config() {
  if [[ ${pgo_mode} == "all" ]]; then
    if ! grep "PGO" $1 >/dev/null; then
      echo "[ERROR] Current version of kernel does not support PGO, please use newer ones or choose arc mode." | tee -a ${log_file}
      exit 1
    fi
    sed -i 's/.*CONFIG_PGO_KERNEL.*/CONFIG_PGO_KERNEL=y/' $1
  fi
  for config in ${kernel_configs[@]}; do
    sed -i "s/.*${config%%=*}.*/${config}/" $1
  done
  sed -i "s/CONFIG_LOCALVERSION=\"\"/CONFIG_LOCALVERSION=\"-${kernel_name}-pgoing\"/" $1
  sed -i 's/.*CONFIG_GCOV_KERNEL.*/CONFIG_GCOV_KERNEL=y/' $1
  sed -i '/CONFIG_ARCH_HAS_GCOV_PROFILE_ALL/ a\CONFIG_GCOV_PROFILE_ALL=y' $1
  sed -i '/CONFIG_CC_HAS_ASM_INLINE/ a\CONFIG_CONSTRUCTORS=y' $1
  sed -i '/CONFIG_TRACE_EVAL_MAP_FILE/ a\# CONFIG_GCOV_PROFILE_FTRACE is not set' $1
}

# 编译插桩版本的内核
function first_compilation() {
  if [[ -n ${disable_compilation} ]]; then
    modify_kernel_config ${kernel_config}
    echo "[INFO] Kernel configuration has been generated, the path is: ${kernel_config}" | tee -a ${log_file}
    if [[ -z ${option} ]]; then
      sed -i "/KBUILD_CFLAGS   += \$(KCFLAGS)/ a\KBUILD_CFLAGS   += fkernel-pgo" ${makefile}
    fi
    echo "[INFO] Kernel makefile has been generated, the path is: ${makefile}" | tee -a ${log_file}
    exit 0
  fi

  if [[ -z ${kernel_src} ]]; then
    echo "[WARNING] ${kernel_src} is not specified, A-FOT will download and build kernel source code automatically in 10 seconds." | tee -a ${log_file}
    sleep 10
    oe_version=$(grep 'openeulerversion' /etc/openEuler-latest | cut -d '=' -f 2)
    echo "[INFO] Current openEuler version: ${oe_version}" | tee -a ${log_file}
    url="https://repo.huaweicloud.com/openeuler/${oe_version}/source/Packages/"
    echo "[INFO] Download the kernel source rpm package from ${url}" | tee -a ${log_file}
    cd ${work_path}
    wget --no-parent --no-directories -r -A 'kernel-[0-9]*.rpm' ${url} --no-check-certificate >>${log_file} 2>&1
    is_success $?
    srpm=$(ls -t kernel-[0-9]*.rpm 2>/dev/null | head -n 1)
    echo "[INFO] Successfully downloaded kernel source rpm package: ${srpm}" | tee -a ${log_file}
    echo "[INFO] Build kernel source code." | tee -a ${log_file}
    rpm -ivh ${srpm} >>${log_file} 2>&1
    cd - >/dev/null
    rpmbuild -bp ~/rpmbuild/SPECS/kernel.spec >>${log_file} 2>&1
    is_success $?
    src_dir=$(ls -td ~/rpmbuild/BUILD/kernel-*/*-source/ | head -n 1)
    cp -r ${src_dir} ${work_path}/kernel
    kernel_src=${work_path}/kernel
    echo "[INFO] Successfully builded kernel source code: ${kernel_src}" | tee -a ${log_file}
  else
    echo "[INFO] Build kernel in an existing source directory." | tee -a ${log_file}
  fi

  if [[ ! -d ${kernel_src} ]]; then
    echo "[ERROR] Kernel source directory ${kernel_src} does not exist." | tee -a ${log_file}
    exit 1
  fi

  cd ${kernel_src}
  make openeuler_defconfig
  modify_kernel_config .config
  echo "[INFO] Start PGO kernel compilation." | tee -a ${log_file}
  arch=$(arch | sed -e s/x86_64/x86/ -e s/aarch64.*/arm64/)
  (make clean -j ${parallel} && make KCFLAGS="${option}" ARCH=${arch} -j ${parallel} && make modules_install ARCH=${arch} -j ${parallel} && make install ARCH=${arch} -j ${parallel}) 2>&1 | tee -a ${log_file}
  is_success ${PIPESTATUS[0]}
  cd - >/dev/null
}

# 第一次重启操作
function first_reboot() {
  next_cmd="${afot_path}/a-fot --opt_mode Auto_kernel_PGO --pgo_phase 2 --kernel_src ${kernel_src} --kernel_name ${kernel_name} --work_path ${work_path} --run_script ${run_script} --compiler_path ${compiler_path} --last_time ${now_time} -s"
  for config in ${kernel_configs[@]}; do
    next_cmd+=" --${config}"
  done

  grub2-set-default 0
  if [[ -z ${silent} ]]; then
    read -p $'PGO kernel has been successfully installed. Reboot now to use?\nPress [y] to reboot now, [n] to reboot yourself later: ' reboot_p
    if [[ ${reboot_p} == "y" ]]; then
      echo "[WARNING] System will be rebooted in 10 seconds!!!" | tee -a ${log_file}
      echo -e "[INFO] Please run this command to continue after rebooting:\n${next_cmd}" | tee -a ${log_file}
      sleep 10
      reboot
    else
      echo -e "[INFO] Please run this command to continue after rebooting:\n${next_cmd}" | tee -a ${log_file}
    fi
  else
    echo "[WARNING] System will be rebooted in 10 seconds!!!" | tee -a ${log_file}
    sleep 10
    echo ${next_cmd} >>/etc/rc.d/rc.local
    chmod +x /etc/rc.d/rc.local
    reboot
  fi
  exit 0
}

# 执行应用程序执行脚本
function execute_run_script() {
  echo "[INFO] Start to execute the run_script: ${run_script}" | tee -a ${log_file}
  /bin/bash ${run_script} >>${log_file} 2>&1
  is_success $?
}

# 收集和处理profile文件
function process_profiles() {
  if [[ -z ${disable_compilation} ]]; then
    data_dir=/sys/kernel/debug/gcov
  fi
  if [[ ! -d ${data_dir} ]]; then
    echo "[ERROR] GCOV data directory ${data_dir} does not exist." | tee -a ${log_file}
    exit 1
  fi

  temp_dir=$(mktemp -d)
  cd ${work_path}
  echo "[INFO] Start collecting the profiles." | tee -a ${log_file}
  find ${data_dir} -type d -exec mkdir -p ${temp_dir}/\{\} \;
  find ${data_dir} -name '*.gcda' -exec sh -c 'cat < $0 > '${temp_dir}'/$0' {} \;
  find ${data_dir} -name '*.gcno' -exec sh -c 'cp -d $0 '${temp_dir}'/$0' {} \;

  echo "[INFO] Start post-processing the profiles." | tee -a ${log_file}
  find ${temp_dir} -name '*.gcda' >list.txt
  calcsum=${afot_path}/calcsum
  if [[ ! -f ${calcsum} ]]; then
    /usr/bin/g++ ${afot_path}/GcovSummaryAddTool.cpp -o ${calcsum}
  fi
  ${calcsum} list.txt
  rm -f list.txt

  profile_dir=${time_dir}/gcovdata
  rm -rf ${profile_dir}
  mkdir ${profile_dir}
  for file in $(find ${temp_dir} -name '*.gcda'); do
    hash_path=$(echo ${file//\//\#})
    name=$(echo ${hash_path#*gcov})
    mv $file ${profile_dir}/$name
  done
  rm -rf ${temp_dir}
  cd - >/dev/null
  echo "[INFO] Profiles have been successfully processed, the path is: ${profile_dir}" | tee -a ${log_file}
}

# 使用profile编译优化的内核
function second_compilation() {
  if [[ -n ${disable_compilation} ]]; then
    sed -i "/KBUILD_CFLAGS   += \$(KCFLAGS)/ a\KBUILD_CFLAGS   += -fprofile-use -fprofile-correction -Wno-error=coverage-mismatch -Wno-error=missing-profile -fprofile-dir=${profile_dir}" ${makefile}
    echo "[INFO] Kernel makefile has been generated, the path is: ${makefile}" | tee -a ${log_file}
    exit 0
  fi

  if [[ -z ${kernel_src} ]]; then
    kernel_src=${work_path}/kernel
  fi
  if [[ ! -d ${kernel_src} ]]; then
    echo "[ERROR] Kernel source directory ${kernel_src} does not exist." | tee -a ${log_file}
    exit 1
  fi

  if [[ -f ${time_dir}/.flag ]]; then
    rm -f ${time_dir}/.flag
  else
    next_cmd="${afot_path}/a-fot --opt_mode Auto_kernel_PGO --pgo_phase 2 --kernel_src ${kernel_src} --kernel_name ${kernel_name} --work_path ${work_path} --run_script ${run_script} --compiler_path ${compiler_path} --last_time ${now_time} -s"
    for config in ${kernel_configs[@]}; do
      next_cmd+=" --${config}"
    done
    echo "[INFO] Switch to normal kernel for faster compilation." | tee -a ${log_file}
    echo "[WARNING] System will be rebooted in 10 seconds!!!" | tee -a ${log_file}
    sleep 10
    touch ${time_dir}/.flag
    echo ${next_cmd} >>/etc/rc.d/rc.local
    chmod +x /etc/rc.d/rc.local
    grub2-set-default 1
    reboot
    exit 0
  fi

  cd ${kernel_src}
  make openeuler_defconfig
  for config in ${kernel_configs[@]}; do
    sed -i 's/.*${config%%=*}.*/${config}/' .config
  done
  sed -i "s/CONFIG_LOCALVERSION=\"\"/CONFIG_LOCALVERSION=\"-${kernel_name}-pgoed\"/" .config
  echo "[INFO] Start optimized kernel compilation." | tee -a ${log_file}
  arch=$(arch | sed -e s/x86_64/x86/ -e s/aarch64.*/arm64/)
  (make clean -j ${parallel} && make KCFLAGS="-fprofile-use -fprofile-correction -Wno-error=coverage-mismatch -Wno-error=missing-profile -fprofile-dir=${time_dir}/gcovdata" -j ${parallel} && make modules_install ARCH=${arch} -j ${parallel} && make install ARCH=${arch} -j ${parallel}) 2>&1 | tee -a ${log_file}
  is_success ${PIPESTATUS[0]}
  cd - >/dev/null
}

# 第二次重启操作
function second_reboot() {
  grub2-set-default 0
  if [[ -z ${silent} ]]; then
    read -p $'Optimized kernel has been successfully installed. Reboot now to use?\nPress [y] to reboot now, [n] to reboot yourself later: ' reboot_p
  fi
  if [[ -n ${silent} ]] || [[ ${reboot_p} == "y" ]]; then
    echo "[WARNING] System will be rebooted in 10 seconds!!!" | tee -a ${log_file}
    sleep 10
    reboot
    exit 0
  fi
}

# 执行入口
function main() {
  cancel_afot_rc
  check_config_items
  check_dependency
  init
  if [[ ${pgo_phase} -eq 1 ]]; then
    first_compilation
    first_reboot
  fi
  if [[ ${pgo_phase} -eq 2 ]]; then
    if [[ ! -f ${time_dir}/.flag ]]; then
      execute_run_script
      process_profiles
    fi
    second_compilation
    second_reboot
  fi
  exit "$?"
}

main
exit "$?"
