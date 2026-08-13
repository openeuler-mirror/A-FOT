#!/bin/bash

set -euo pipefail

mysql_install_path=/home/workspace/mysql-cfgo
mysql_data_root=/data/mysql
mysql_baseline_root=/data/mysql_sysbench_20x1000000
mysql_data_dir=${mysql_data_root}/data
mysql_log_dir=${mysql_data_root}/log
mysql_run_dir=${mysql_data_root}/run
mysql_tmp_dir=${mysql_data_root}/tmp
mysql_err_log=${mysql_log_dir}/mysqld.err
mysql_pid_file=${mysql_run_dir}/mysqld.pid
mysql_socket=${mysql_run_dir}/mysqld.sock
mysql_port=3306
mysql_user=root
mysql_password=123456
mysql_host=127.0.0.1
ready_timeout=${MYSQL_READY_TIMEOUT:-120}
sysbench_table_size=${SYSBENCH_TABLE_SIZE:-1000000}
sysbench_tables=${SYSBENCH_TABLES:-20}
sysbench_read_only_time_1=${SYSBENCH_TIME_READ1:-300}
sysbench_read_only_time_2=${SYSBENCH_TIME_READ2:-180}
sysbench_read_write_time=${SYSBENCH_TIME_READ_WRITE:-180}
sysbench_write_only_time=${SYSBENCH_TIME_WRITE_ONLY:-180}
sysbench_read_only_threads_1=${SYSBENCH_THREADS_READ1:-64}
sysbench_read_only_threads_2=${SYSBENCH_THREADS_READ2:-64}
sysbench_read_write_threads=${SYSBENCH_THREADS_READ_WRITE:-256}
sysbench_write_only_threads=${SYSBENCH_THREADS_WRITE_ONLY:-512}

mysqld_bin=${MYSQLD_BIN:-${mysql_install_path}/bin/mysqld}
mysql_bin=${mysql_install_path}/bin/mysql
mysqladmin_bin=${mysql_install_path}/bin/mysqladmin
sysbench_bin=$(command -v sysbench || true)
numactl_bin=$(command -v numactl || true)
pkill_bin=$(command -v pkill || true)

mysqld_pid=""

function log_info() {
  printf '[INFO] %s\n' "$1"
}

function log_warn() {
  printf '[WARN] %s\n' "$1"
}

function log_error() {
  printf '[ERROR] %s\n' "$1" >&2
}

function fail() {
  log_error "$1"
  print_mysql_error_summary
  exit 1
}

function require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "缺少文件：${path}"
  fi
}

function require_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    fail "缺少目录：${path}"
  fi
}

function require_baseline_layout() {
  local subdir
  for subdir in data log run tmp; do
    if [[ ! -d "${mysql_baseline_root}/${subdir}" ]]; then
      fail "基线目录结构不正确：缺少 ${mysql_baseline_root}/${subdir}。当前应直接包含 data/log/run/tmp，而不是额外包一层目录。"
    fi
  done
}

function require_command_path() {
  local path="$1"
  local name="$2"
  if [[ -z "$path" ]]; then
    fail "未找到命令：${name}"
  fi
}

function print_mysql_error_summary() {
  if [[ -f "${mysql_err_log}" ]]; then
    log_error "mysqld 错误日志：${mysql_err_log}"
    tail -n 40 "${mysql_err_log}" >&2 || true
  fi
}

function stop_existing_mysqld() {
  local existing_pids
  existing_pids=$(pgrep -x mysqld || true)
  if [[ -z "${existing_pids}" ]]; then
    return
  fi

  log_warn "检测到残留 mysqld 进程，准备清理：${existing_pids}"
  if [[ -f "${mysql_pid_file}" ]]; then
    "${mysqladmin_bin}" --socket="${mysql_socket}" --user="${mysql_user}" --password="${mysql_password}" shutdown >/dev/null 2>&1 || true
  fi
  "${pkill_bin}" -x mysqld >/dev/null 2>&1 || true

  local wait_sec=0
  while pgrep -x mysqld >/dev/null 2>&1; do
    sleep 1
    wait_sec=$((wait_sec + 1))
    if [[ ${wait_sec} -gt 30 ]]; then
      fail "无法清理残留 mysqld 进程。"
    fi
  done
}

function wait_mysql_ready() {
  local wait_sec=0
  while true; do
    if "${mysqladmin_bin}" --host="${mysql_host}" --port="${mysql_port}" --user="${mysql_user}" --password="${mysql_password}" ping >/dev/null 2>&1; then
      # 部分 PGO/CFGO 二进制在默认 mysql CLI 的首条 SQL 探针上可能异常卡住，
      # 该问题出现在 classic protocol 的结果集结束包路径，mysqladmin status
      # 与后续 sysbench 连接通常仍然正常。这里固定使用 mysqladmin 做就绪
      # 确认，避免把“CLI SQL 探针异常”误判为“实例不可用”。
      if "${mysqladmin_bin}" --host="${mysql_host}" --port="${mysql_port}" --user="${mysql_user}" --password="${mysql_password}" status >/dev/null 2>&1; then
        log_info "mysqld 已就绪，可开始执行采样任务。"
        return
      fi
    fi

    if [[ -n "${mysqld_pid}" ]] && ! ps -p "${mysqld_pid}" >/dev/null 2>&1; then
      fail "mysqld 在就绪前提前退出。"
    fi

    sleep 1
    wait_sec=$((wait_sec + 1))
    if [[ ${wait_sec} -eq 1 || $((wait_sec % 10)) -eq 0 ]]; then
      log_info "mysqld 启动等待中……已等待 ${wait_sec}s。"
    fi
    if [[ ${wait_sec} -ge ${ready_timeout} ]]; then
      fail "mysqld 在 ${ready_timeout}s 内未完成就绪。"
    fi
  done
}

function cleanup() {
  local exit_code=$?
  if pgrep -x mysqld >/dev/null 2>&1; then
    log_info "正在停止 mysqld。"
    "${mysqladmin_bin}" --host="${mysql_host}" --port="${mysql_port}" --user="${mysql_user}" --password="${mysql_password}" shutdown >/dev/null 2>&1 || true
    "${pkill_bin}" -x mysqld >/dev/null 2>&1 || true
  fi
  exit "${exit_code}"
}

function run_sysbench_case() {
  local mode="$1"
  local time_sec="$2"
  local threads="$3"
  log_info "开始执行 sysbench：mode=${mode} time=${time_sec}s threads=${threads}"
  "${numactl_bin}" -C 8-15 "${sysbench_bin}" \
    --db-driver=mysql \
    --mysql-host="${mysql_host}" \
    --mysql-port="${mysql_port}" \
    --mysql-user="${mysql_user}" \
    --mysql-password="${mysql_password}" \
    --mysql-db=sbtest \
    --table_size="${sysbench_table_size}" \
    --tables="${sysbench_tables}" \
    --time="${time_sec}" \
    --threads="${threads}" \
    --report-interval=10 \
    "${mode}" run
  log_info "sysbench 完成：mode=${mode} time=${time_sec}s threads=${threads}"
}

trap cleanup EXIT

require_file "${mysqld_bin}"
require_file "${mysql_bin}"
require_file "${mysqladmin_bin}"
require_file /etc/my.cnf
require_dir "${mysql_baseline_root}"
require_baseline_layout
require_command_path "${sysbench_bin}" "sysbench"
require_command_path "${numactl_bin}" "numactl"
require_command_path "${pkill_bin}" "pkill"

mkdir -p "${mysql_data_root}" "${mysql_log_dir}" "${mysql_run_dir}" "${mysql_tmp_dir}"
rm -f "${mysql_err_log}" "${mysql_pid_file}"

stop_existing_mysqld

if [[ -w /proc/sys/vm/drop_caches ]]; then
  echo 3 > /proc/sys/vm/drop_caches
else
  log_warn "/proc/sys/vm/drop_caches 不可写，跳过清理页缓存"
fi

log_info "恢复基线数据：${mysql_baseline_root} -> ${mysql_data_root}"
rm -rf "${mysql_data_root:?}/"*
cp -r --reflink=never "${mysql_baseline_root}/"* "${mysql_data_root}/"

log_info "启动 mysqld。"
"${numactl_bin}" -C 0-7 "${mysqld_bin}" \
  --defaults-file=/etc/my.cnf \
  --log-error="${mysql_err_log}" \
  --pid-file="${mysql_pid_file}" \
  --socket="${mysql_socket}" &
mysqld_pid=$!

wait_mysql_ready

run_sysbench_case oltp_read_only "${sysbench_read_only_time_1}" "${sysbench_read_only_threads_1}"
run_sysbench_case oltp_read_only "${sysbench_read_only_time_2}" "${sysbench_read_only_threads_2}"
run_sysbench_case oltp_read_write "${sysbench_read_write_time}" "${sysbench_read_write_threads}"
run_sysbench_case oltp_write_only "${sysbench_write_only_time}" "${sysbench_write_only_threads}"
