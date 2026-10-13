#!/usr/bin/env bash
set -euo pipefail

# Запускает два Flask-инстанса для upstream nginx.
# Запускайте из любого каталога:
#   /opt/notes-lab/scripts/run_backends.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${PROJECT_ROOT}/backend"
RUNTIME_DIR="${PROJECT_ROOT}/runtime"

PYTHON_BIN="${PYTHON_BIN:-python3}"

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-notes_db}"
DB_USER="${DB_USER:-notes_user}"
DB_PASSWORD="${DB_PASSWORD:-notes_password}"

mkdir -p "${RUNTIME_DIR}"

if [[ ! -f "${BACKEND_DIR}/app.py" ]]; then
  echo "ERROR: не найден ${BACKEND_DIR}/app.py" >&2
  exit 1
fi

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "ERROR: команда Python не найдена: ${PYTHON_BIN}" >&2
  exit 1
fi

start_backend() {
  local backend_id="$1"
  local port="$2"
  local pid_file="${RUNTIME_DIR}/${backend_id}.pid"
  local log_file="${RUNTIME_DIR}/${backend_id}.log"

  if [[ -f "${pid_file}" ]]; then
    local old_pid
    old_pid="$(cat "${pid_file}")"

    if kill -0 "${old_pid}" 2>/dev/null; then
      echo "INFO: ${backend_id} уже запущен: PID=${old_pid}, port=${port}"
      return 0
    fi

    rm -f "${pid_file}"
  fi

  echo "INFO: запуск ${backend_id} на 127.0.0.1:${port}"

  (
    cd "${BACKEND_DIR}"

    export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
    export PORT="${port}"
    export BACKEND_ID="${backend_id}"

    exec "${PYTHON_BIN}" app.py
  ) >"${log_file}" 2>&1 &

  local pid=$!
  echo "${pid}" >"${pid_file}"

  sleep 1

  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "ERROR: ${backend_id} не запустился. Лог: ${log_file}" >&2
    cat "${log_file}" >&2 || true
    rm -f "${pid_file}"
    exit 1
  fi

  echo "INFO: ${backend_id} запущен: PID=${pid}, лог=${log_file}"
}

start_backend "backend-1" "5001"
start_backend "backend-2" "5002"

echo
echo "Проверка прямого доступа к инстансам:"
curl -sS http://127.0.0.1:5001/api/whoami
echo
curl -sS http://127.0.0.1:5002/api/whoami
echo