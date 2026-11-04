#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${PROJECT_ROOT}/runtime"

for backend_id in backend-1 backend-2; do
  pid_file="${RUNTIME_DIR}/${backend_id}.pid"

  if [[ ! -f "${pid_file}" ]]; then
    echo "INFO: ${backend_id} не запущен (PID-файл не найден)."
    continue
  fi

  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}"
    echo "INFO: остановлен ${backend_id} (PID=${pid})."
  else
    echo "INFO: ${backend_id} уже остановлен."
  fi

  rm -f "${pid_file}"
done