#!/bin/bash

function cfgo_pgo_dir() {
  printf '%s' "${profiles_dir}/cfgo-pgo"
}

function cfgo_cspgo_dir() {
  printf '%s' "${profiles_dir}/cfgo-cspgo"
}

function cfgo_bolt_dir() {
  printf '%s' "${profiles_dir}/cfgo-bolt"
}

# 复用 profile 时，GCC 会按编译路径匹配 profile 中记录的对象路径。
# 通过固定 stable_root 并注入 -fprofile-prefix-path，可减少工作区绝对路径变化带来的命中偏差。
function cfgo_prefix_path_flags() {
  if [[ -n "${stable_root:-}" ]]; then
    printf '%s\n' "-fprofile-prefix-path=${stable_root}"
  fi
}

# 在关键 CFGO 构建阶段保留阶段性二进制，方便后续对比不同 profile 阶段的产物。
function backup_cfgo_binary() {
  local backup_suffix="$1"
  local backup_path="${bin_file}.${backup_suffix}"

  is_file_exist "${bin_file}" "bin_file" "file"
  cp -f "${bin_file}" "${backup_path}" || fail_stage "optimization_flow" 1 "备份阶段二进制失败：${backup_path}" "请检查目标目录权限和磁盘空间。"
  is_file_exist "${backup_path}" "cfgo_backup_binary" "file"

  record_substage_artifact "阶段二进制备份：${backup_path}"
  log_info "已生成阶段二进制备份：${backup_path}"
}

# 某些 build/run 脚本会在后续阶段清空固定输出目录。
# 这里允许用户显式列出高风险目录，在关键阶段结束后归档到 A-FOT 运行目录中。
function backup_cfgo_cleanup_dirs() {
  local backup_suffix="$1"
  local archive_root="${artifacts_dir}/cleanup-backups/${backup_suffix}"

  if [[ -z "${cleanup_backup_dirs:-}" ]]; then
    return 0
  fi

  mkdir -p "${archive_root}" || fail_stage "optimization_flow" 1 "无法创建目录备份路径：${archive_root}" "请检查工作目录权限和磁盘空间。"

  local old_ifs="$IFS"
  IFS=':'
  read -r -a cleanup_dirs <<<"${cleanup_backup_dirs}"
  IFS="$old_ifs"

  local dir_path dir_name archive_path
  for dir_path in "${cleanup_dirs[@]}"; do
    dir_path=$(trim_whitespace "${dir_path}")
    if [[ -z "${dir_path}" ]]; then
      continue
    fi

    if [[ ! -d "${dir_path}" ]]; then
      log_warn "跳过目录备份，目录不存在：${dir_path}"
      record_substage_artifact "目录备份跳过：${dir_path}（不存在）"
      continue
    fi

    dir_name=$(basename "${dir_path}")
    archive_path="${archive_root}/${dir_name}.tar.gz"
    tar -C "$(dirname "${dir_path}")" -czf "${archive_path}" "${dir_name}" || fail_stage "optimization_flow" 1 "目录备份失败：${dir_path}" "请检查目录权限、磁盘空间和 tar 命令是否可用。"
    is_file_exist "${archive_path}" "cfgo_cleanup_archive" "file"

    record_substage_artifact "目录备份归档：${archive_path}"
    log_info "已完成目录备份：${dir_path} -> ${archive_path}"
  done
}

# 检测依赖软件是否已经安装
# 1. 检查基础依赖
# 2. 验证编译器是否为 GCC
# 3. 验证 GCC 是否支持 -fcfgo-profile-generate 选项
function check_dependency() {
  check_common_dependency

  if [[ "$compiler" != "gcc" ]]; then
    fail_stage "check_dependency" 1 "优化模式 ${opt_mode} 仅支持 GCC 编译器。" "请将 compiler 设置为 gcc。"
  fi

  if ! "${compiler_path}/bin/${c_compiler}" -fcfgo-profile-generate -E -x c /dev/null >/dev/null 2>&1; then
    fail_stage "check_dependency" 1 "当前 GCC 不支持 -fcfgo-profile-generate 选项。" "请确认编译器版本是否满足 CFGO 要求。"
  fi

  if [[ ! -f "${compiler_path}/bin/llvm-bolt" ]]; then
    fail_stage "check_dependency" 1 "在 ${compiler_path}/bin/ 下未找到 llvm-bolt。" "请安装支持的 llvm-bolt。"
  fi

  if ! "${compiler_path}/bin/llvm-bolt" --help | grep -q -- "-Om"; then
    fail_stage "check_dependency" 1 "当前 llvm-bolt 不支持 -Om 选项。" "请升级到支持该选项的版本。"
  fi
}

function write_single_wrapper() {
  local stage_name="$1"
  local lang="$2"
  local compiler_bin="$3"
  local wrapper_path="$4"
  shift 4

  local flags=("$@")
  local trace_flags
  trace_flags=$(printf '%q ' "${flags[@]}")
  {
    printf '#!/bin/bash\n'
    printf '# 阶段：%s\n' "$stage_name"
    printf '# 生成时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# 注入参数：%s\n' "$trace_flags"
    printf '# trace文件：%s\n' "$compile_trace_file"
    printf 'set -o pipefail\n'
    printf 'trace_file=%q\n' "$compile_trace_file"
    printf 'stage_name=%q\n' "$stage_name"
    printf 'lang_name=%q\n' "$lang"
    printf 'compiler_bin=%q\n' "$compiler_bin"
    printf 'inject_flags=('
    local flag
    for flag in "${flags[@]}"; do
      printf ' %q' "$flag"
    done
    printf ' )\n'
    cat <<'EOF'
argv_quoted=$(printf '%q ' "$@")

printf 'timestamp=%s stage=%s lang=%s compiler=%s inject="%s" argv="%s"\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" \
  "$stage_name" \
  "$lang_name" \
  "$compiler_bin" \
  "${inject_flags[*]}" \
  "$argv_quoted" >>"$trace_file" || exit 1
exec "$compiler_bin" "${inject_flags[@]}" "$@"
EOF
  } >"$wrapper_path"

  chmod 755 "$wrapper_path"
  dump_file_to_logs "Wrapper脚本" "$wrapper_path"
}

function create_stage_wrappers() {
  local stage_name="$1"
  shift
  local c_flags=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    c_flags+=("$1")
    shift
  done
  shift
  local cxx_flags=("$@")

  mkdir -p "${compiler_wrapper}" || fail_stage "optimization_flow" 1 "无法创建 wrapper 目录 ${compiler_wrapper}。" "请检查工作目录权限。"
  write_single_wrapper "$stage_name" "C" "${compiler_path}/bin/${c_compiler}" "${compiler_wrapper}/${c_compiler}" "${c_flags[@]}"
  write_single_wrapper "$stage_name" "CXX" "${compiler_path}/bin/${cxx_compiler}" "${compiler_wrapper}/${cxx_compiler}" "${cxx_flags[@]}"
  post_create_wrapper

  record_substage_artifact "Wrapper目录：${compiler_wrapper}"
  record_substage_artifact "Compile trace：${compile_trace_file}"
}

# CFGO-PGO 环境准备
function prepare_env() {
  log_info "开始准备 CFGO-PGO 环境。"
  local pgo_dir
  local prefix_flags=()
  pgo_dir=$(cfgo_pgo_dir)
  mapfile -t prefix_flags < <(cfgo_prefix_path_flags)
  case "${build_mode}" in
  "Wrapper")
    create_cfgo_pgo_wrapper
    ;;
  "Bear")
    mkdir -p "$pgo_dir" || fail_stage "optimization_flow" 1 "无法创建 CFGO-PGO profile 目录 ${pgo_dir}。" "请检查目录权限。"
    export COMPILATION_OPTIONS="${prefix_flags[*]} -fcfgo-profile-generate=${pgo_dir}"
    export LINK_OPTIONS="${prefix_flags[*]} -fcfgo-profile-generate=${pgo_dir}"
    ;;
  *)
    fail_stage "optimization_flow" 1 "构建模式 ${build_mode} 不受支持。" "请将 build_mode 设置为 Wrapper 或 Bear。"
    ;;
  esac
  record_substage_artifact "CFGO-PGO profile目录：${pgo_dir}"
  if [[ -n "${stable_root:-}" ]]; then
    record_substage_artifact "CFGO stable_root：${stable_root}"
  fi
}

# 等待应用程序执行完成并检查状态
function profiling() {
  if [[ -z "${run_script_pid}" ]]; then
    fail_stage "optimization_flow" 1 "未找到 run_script_pid，无法等待运行脚本结束。" "请检查运行脚本启动逻辑。"
  fi

  log_info "等待运行脚本结束，PID：${run_script_pid}"
  wait "${run_script_pid}"
  local exit_status=$?
  if [[ $exit_status -ne 0 ]]; then
    fail_stage "optimization_flow" "$exit_status" "运行脚本异常退出。" "请查看当前阶段日志定位运行失败原因。"
  fi

  log_info "运行脚本执行完成。"
}

# CFGO-CSPGO 环境准备
function prepare_new_env() {
  log_info "开始准备 CFGO-CSPGO 环境。"
  local pgo_dir cspgo_dir
  local prefix_flags=()
  pgo_dir=$(cfgo_pgo_dir)
  cspgo_dir=$(cfgo_cspgo_dir)
  mapfile -t prefix_flags < <(cfgo_prefix_path_flags)
  case "${build_mode}" in
  "Wrapper")
    create_cfgo_cspgo_wrapper
    ;;
  "Bear")
    mkdir -p "$pgo_dir" "$cspgo_dir" || fail_stage "optimization_flow" 1 "无法创建 CFGO-CSPGO profile 目录。" "请检查目录权限。"
    export COMPILATION_OPTIONS="${prefix_flags[*]} -fcfgo-profile-use=${pgo_dir} -fcfgo-csprofile-generate=${cspgo_dir} -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction"
    export LINK_OPTIONS="${prefix_flags[*]} -fcfgo-profile-use=${pgo_dir} -fcfgo-csprofile-generate=${cspgo_dir} -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction"
    ;;
  *)
    fail_stage "optimization_flow" 1 "构建模式 ${build_mode} 不受支持。" "请将 build_mode 设置为 Wrapper 或 Bear。"
    ;;
  esac
  record_substage_artifact "CFGO-PGO profile目录：${pgo_dir}"
  record_substage_artifact "CFGO-CSPGO profile目录：${cspgo_dir}"
  if [[ -n "${stable_root:-}" ]]; then
    record_substage_artifact "CFGO stable_root：${stable_root}"
  fi
}

# CFGO-BOLT 环境准备
function prepare_bolt_env() {
  log_info "开始准备 CFGO-BOLT 环境。"
  local pgo_dir cspgo_dir
  local prefix_flags=()
  pgo_dir=$(cfgo_pgo_dir)
  cspgo_dir=$(cfgo_cspgo_dir)
  mapfile -t prefix_flags < <(cfgo_prefix_path_flags)
  case "${build_mode}" in
  "Wrapper")
    create_bolt_wrapper
    ;;
  "Bear")
    export COMPILATION_OPTIONS="${prefix_flags[*]} -fcfgo-profile-use=${pgo_dir} -fcfgo-csprofile-use=${cspgo_dir} -Wl,-q -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction"
    export LINK_OPTIONS="${prefix_flags[*]} -fcfgo-profile-use=${pgo_dir} -fcfgo-csprofile-use=${cspgo_dir} -Wl,-q -Wno-error=missing-profile -Wno-error=coverage-mismatch -fprofile-correction"
    ;;
  *)
    fail_stage "optimization_flow" 1 "构建模式 ${build_mode} 不受支持。" "请将 build_mode 设置为 Wrapper 或 Bear。"
    ;;
  esac
  record_substage_artifact "CFGO-PGO profile目录：${pgo_dir}"
  record_substage_artifact "CFGO-CSPGO profile目录：${cspgo_dir}"
  if [[ -n "${stable_root:-}" ]]; then
    record_substage_artifact "CFGO stable_root：${stable_root}"
  fi
}

# 生成 CFGO-PGO 插桩 wrapper
function create_cfgo_pgo_wrapper() {
  local pgo_dir
  local prefix_flags=()
  pgo_dir=$(cfgo_pgo_dir)
  mapfile -t prefix_flags < <(cfgo_prefix_path_flags)
  mkdir -p "$pgo_dir" || fail_stage "optimization_flow" 1 "无法创建 CFGO-PGO profile 目录 ${pgo_dir}。" "请检查目录权限。"
  create_stage_wrappers "${current_substage:-cfgo-pgo}" \
    "${prefix_flags[@]}" \
    "-fcfgo-profile-generate=${pgo_dir}" -- \
    "${prefix_flags[@]}" \
    "-fcfgo-profile-generate=${pgo_dir}"
}

# 生成 CFGO-CSPGO 插桩 wrapper
function create_cfgo_cspgo_wrapper() {
  local pgo_dir cspgo_dir
  local prefix_flags=()
  pgo_dir=$(cfgo_pgo_dir)
  cspgo_dir=$(cfgo_cspgo_dir)
  mapfile -t prefix_flags < <(cfgo_prefix_path_flags)
  mkdir -p "$pgo_dir" "$cspgo_dir" || fail_stage "optimization_flow" 1 "无法创建 CFGO-CSPGO profile 目录。" "请检查目录权限。"
  create_stage_wrappers "${current_substage:-cfgo-cspgo}" \
    "${prefix_flags[@]}" \
    "-fcfgo-profile-use=${pgo_dir}" \
    "-fcfgo-csprofile-generate=${cspgo_dir}" \
    "-Wno-error=missing-profile" \
    "-Wno-error=coverage-mismatch" \
    "-fprofile-correction" -- \
    "${prefix_flags[@]}" \
    "-fcfgo-profile-use=${pgo_dir}" \
    "-fcfgo-csprofile-generate=${cspgo_dir}" \
    "-Wno-error=missing-profile" \
    "-Wno-error=coverage-mismatch" \
    "-fprofile-correction"
}

# 生成 CFGO-BOLT wrapper
function create_bolt_wrapper() {
  local pgo_dir cspgo_dir
  local prefix_flags=()
  pgo_dir=$(cfgo_pgo_dir)
  cspgo_dir=$(cfgo_cspgo_dir)
  mapfile -t prefix_flags < <(cfgo_prefix_path_flags)
  mkdir -p "$pgo_dir" "$cspgo_dir" || fail_stage "optimization_flow" 1 "无法创建 CFGO-BOLT 依赖目录。" "请检查目录权限。"
  create_stage_wrappers "${current_substage:-cfgo-bolt}" \
    "${prefix_flags[@]}" \
    "-fcfgo-profile-use=${pgo_dir}" \
    "-fcfgo-csprofile-use=${cspgo_dir}" \
    "-Wno-error=missing-profile" \
    "-Wno-error=coverage-mismatch" \
    "-fprofile-correction" \
    "-Wl,-q" -- \
    "${prefix_flags[@]}" \
    "-fcfgo-profile-use=${pgo_dir}" \
    "-fcfgo-csprofile-use=${cspgo_dir}" \
    "-Wno-error=missing-profile" \
    "-Wno-error=coverage-mismatch" \
    "-fprofile-correction" \
    "-Wl,-q"
}

function do_bolt_instrument() {
  local stage_log bolt_dir
  stage_log=$(get_active_log_file)
  bolt_dir=$(cfgo_bolt_dir)

  is_file_exist "${compiler_path}/bin/llvm-bolt" "compiler_path" "executable"
  mkdir -p "$bolt_dir" || fail_stage "optimization_flow" 1 "无法创建 BOLT profile 目录 ${bolt_dir}。" "请检查目录权限。"

  local bolt_cmd=(
    "${compiler_path}/bin/llvm-bolt"
    --instrument "${bin_file}"
    -o "${bin_file}.inst.bolt"
    -instrumentation-file="${bolt_dir}/bolt.inst.fdata"
    --instrumentation-wait-forks
    --instrumentation-sleep-time=2
    --instrumentation-no-counters-clear
  )

  {
    printf '\n# [%s] 执行 BOLT 插桩命令：\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf '%q ' "${bolt_cmd[@]}"
    printf '\n'
    printf '输入文件：%s\n输出文件：%s\n' "${bin_file}" "${bin_file}.inst.bolt"
  } >>"$stage_log"

  "${bolt_cmd[@]}" >>"$stage_log" 2>&1
  local bolt_rc=$?
  printf '返回码：%s\n' "$bolt_rc" >>"$stage_log"
  if [[ $bolt_rc -ne 0 ]]; then
    fail_stage "optimization_flow" "$bolt_rc" "BOLT 插桩失败。" "请查看当前阶段日志中的 BOLT 命令输出。"
  fi

  is_file_exist "${bin_file}.inst.bolt" "bin_file" "file"
  mv "${bin_file}" "${bin_file}.orig" || fail_stage "optimization_flow" 1 "备份原始二进制失败。" "请检查目标文件权限。"
  mv "${bin_file}.inst.bolt" "${bin_file}" || fail_stage "optimization_flow" 1 "替换插桩二进制失败。" "请检查目标文件权限。"

  record_substage_artifact "原始二进制备份：${bin_file}.orig"
  record_substage_artifact "插桩后二进制：${bin_file}"
  record_substage_artifact "BOLT fdata：${bolt_dir}/bolt.inst.fdata"
  log_info "BOLT 插桩完成。"
}

function do_bolt_opt() {
  local stage_log bolt_dir
  stage_log=$(get_active_log_file)
  bolt_dir=$(cfgo_bolt_dir)

  is_file_exist "${bolt_dir}/bolt.inst.fdata" "cfgo_bolt_fdata" "file"
  is_file_exist "${bin_file}.orig" "bin_file" "file"

  mv "${bin_file}" "${bin_file}.inst.bolt" || fail_stage "optimization_flow" 1 "备份 BOLT 插桩二进制失败。" "请检查目标文件权限。"

  local bolt_opt_cmd=(
    "${compiler_path}/bin/llvm-bolt"
    "${bin_file}.orig"
    -o "${bin_file}"
    -data="${bolt_dir}/bolt.inst.fdata"
    -dyno-stats
    -Om
  )

  {
    printf '\n# [%s] 执行 BOLT 优化命令：\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf '%q ' "${bolt_opt_cmd[@]}"
    printf '\n'
    printf '输入文件：%s\n输出文件：%s\n' "${bin_file}.orig" "${bin_file}"
  } >>"$stage_log"

  "${bolt_opt_cmd[@]}" >>"$stage_log" 2>&1
  local bolt_rc=$?
  printf '返回码：%s\n' "$bolt_rc" >>"$stage_log"
  if [[ $bolt_rc -ne 0 ]]; then
    fail_stage "optimization_flow" "$bolt_rc" "BOLT 优化失败。" "请查看当前阶段日志中的 BOLT 命令输出。"
  fi

  is_file_exist "${bin_file}" "bin_file" "file"
  record_substage_artifact "优化后最终二进制：${bin_file}"
  record_substage_artifact "插桩二进制备份：${bin_file}.inst.bolt"
  record_substage_artifact "原始二进制保留：${bin_file}.orig"
  log_info "BOLT 优化完成。"
}
