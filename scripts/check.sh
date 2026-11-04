#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNTIME_DIR="${PROJECT_ROOT}/runtime"

HTTP_URL="${HTTP_URL:-http://notes.local}"
HTTPS_URL="${HTTPS_URL:-https://notes.local}"
SECOND_URL="${SECOND_URL:-https://second.local}"

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-lab1admin}"

CURL_BASE=(curl --silent --show-error --insecure)
PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '\nPASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '\nFAIL: %s\n' "$1"
}

section() {
  printf '\n============================================================\n'
  printf '%s\n' "$1"
  printf '============================================================\n'
}

contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "${needle}" <<<"${haystack}"
}

http_status() {
  local url="$1"
  shift

  "${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' "$@" "${url}" 2>/dev/null
}

print_headers() {
  local url="$1"
  shift

  "${CURL_BASE[@]}" -D - -o /dev/null "$@" "${url}" || true
}

cleanup_backend_1() {
  local exit_code=$?
  trap - EXIT
  local pid_file="${RUNTIME_DIR}/backend-1.pid"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"

    if kill -0 "${pid}" 2>/dev/null; then
      echo "INFO: cleanup: перезапуск backend-1 (PID=${pid})"
      kill "${pid}" || true
      sleep 1
    fi

    rm -f "${pid_file}"
  fi

  "${SCRIPT_DIR}/run_backend.sh" >/dev/null 2>&1 || true
  exit "${exit_code}"
}

trap cleanup_backend_1 EXIT

section "0. Предварительная проверка доступности nginx и backend-пула"

echo "HTTP:  ${HTTP_URL}"
echo "HTTPS: ${HTTPS_URL}"
echo "Second host: ${SECOND_URL}"
echo

health_headers="$(print_headers "${HTTPS_URL}/health")"
echo "${health_headers}"

if grep -Eq "HTTP/[0-9.]+ 200" <<<"${health_headers}"; then
  pass "nginx отвечает по HTTPS."
else
  fail "nginx не отвечает по HTTPS. Проверьте nginx, hosts и сертификат."
fi

section "1. HTTP должен редиректить на HTTPS (301)"

redirect_headers="$(print_headers "${HTTP_URL}/")"
echo "${redirect_headers}"

if grep -Eq "HTTP/[0-9.]+ 301" <<<"${redirect_headers}" && grep -qiF "Location: https://notes.local/" <<<"${redirect_headers}"; then
  pass "HTTP → HTTPS: получен 301 с Location: https://notes.local/."
else
  fail "Нет ожидаемого HTTP 301 или неверный Location."
fi

section "2. Балансировка: /api/whoami должен показать backend-1 и backend-2"

declare -A SEEN_BACKENDS=()
WHOAMI_OUTPUT=""

for i in {1..8}; do
  echo
  echo "--- Запрос ${i} ---"

  response="$("${CURL_BASE[@]}" --include "${HTTPS_URL}/api/whoami" || true)"
  echo "${response}"

  backend_id="$(grep -i '^X-Backend-ID:' <<<"${response}" | tr -d '\r' | awk '{print $2}' | tail -n 1 || true)"
  if [[ -n "${backend_id}" ]]; then
    SEEN_BACKENDS["${backend_id}"]=1
  fi

  sleep 0.3
done

if [[ -n "${SEEN_BACKENDS[backend-1]+x}" && -n "${SEEN_BACKENDS[backend-2]+x}" ]]; then
  pass "Round-robin подтверждён: в ответах видны backend-1 и backend-2."
else
  fail "Не удалось увидеть оба инстанса. Видны: ${!SEEN_BACKENDS[*]:-none}"
fi

section "3. /admin без пароля должен вернуть 401"

admin_headers="$(print_headers "${HTTPS_URL}/admin/")"
echo "${admin_headers}"

if contains "${admin_headers}" "HTTP/1.1 401"; then
  pass "/admin защищён auth_basic: без пароля получен 401."
else
  fail "/admin без пароля не вернул 401."
fi

section "4. /admin с тестовым паролем должен вернуть 200"

admin_auth_headers="$(print_headers "${HTTPS_URL}/admin/" -u "${ADMIN_USER}:${ADMIN_PASSWORD}")"
echo "${admin_auth_headers}"

if contains "${admin_auth_headers}" "HTTP/1.1 200"; then
  pass "/admin с корректной Basic Auth отвечает 200."
else
  fail "/admin с ADMIN_USER/ADMIN_PASSWORD не вернул 200. Проверьте htpasswd и переменные."
fi

section "5. limit_req: серия запросов должна дать HTTP 429"

RATE_CODES="$(seq 1 40 | xargs -P 20 -I {} curl --silent --show-error --insecure -o /dev/null -w '%{http_code}\n' "${HTTPS_URL}/api/whoami")"

echo "HTTP-коды параллельных запросов:"
printf '%s\n' "${RATE_CODES}"

if grep -qx '429' <<<"${RATE_CODES}"; then
  pass "Rate limit сработал: получен HTTP 429."
else
  fail "Не получен HTTP 429. Возможно, изменён rate/burst или запросы выполнялись слишком медленно."
fi

sleep 2

section "6. Статика: frontend, /docs/ и second.local"

frontend_body="$("${CURL_BASE[@]}" "${HTTPS_URL}/" || true)"
if contains "${frontend_body}" "Мои заметки"; then
  pass "Главная страница Notes Service отдаётся nginx."
else
  fail "Главная страница Notes Service недоступна или содержит неожиданный ответ."
fi

docs_body="$("${CURL_BASE[@]}" "${HTTPS_URL}/docs/" || true)"
if contains "${docs_body}" "директиву" && contains "${docs_body}" "alias"; then
  pass "/docs/ отдаёт документацию через alias."
else
  fail "/docs/ недоступен или не содержит ожидаемую страницу."
fi

second_body="$("${CURL_BASE[@]}" "${SECOND_URL}/" || true)"
echo "${second_body}"

if contains "${second_body}" "Second Local Project" && ! contains "${second_body}" "Мои заметки"; then
  pass "second.local отдаёт отдельный сайт, а не фронтенд заметок."
else
  fail "second.local отдал неожиданный контент."
fi

second_body="$("${CURL_BASE[@]}" "${SECOND_URL}/" || true)"
echo "${second_body}"

if contains "${second_body}" "Second Local Project" && ! contains "${second_body}" "Мои заметки"; then
  pass "second.local отдаёт только второй проект, а не фронтенд заметок."
else
  fail "second.local отдал неожиданный контент."
fi

echo
echo "--- Неизвестный Host должен быть отклонён catch-all virtual host ---"
unknown_headers="$(print_headers "https://127.0.0.1/" -H "Host: unknown.local")"
echo "${unknown_headers}"

if ! contains "${unknown_headers}" "200 OK" && ! contains "${unknown_headers}" "Мои заметки"; then
  pass "Неизвестный Host не получил контент notes.local."
else
  fail "Неизвестный Host получил успешный ответ/контент соседнего сайта."
fi

section "7. Несуществующая страница: кастомная 404"

not_found_headers="$(print_headers "${HTTPS_URL}/this-page-does-not-exist")"
not_found_body="$("${CURL_BASE[@]}" "${HTTPS_URL}/this-page-does-not-exist" || true)"

echo "HEADERS:"
echo "${not_found_headers}"
echo "BODY:"
echo "${not_found_body}"

if contains "${not_found_headers}" "HTTP/1.1 404" && contains "${not_found_body}" "404 — Страница не найдена"; then
  pass "Кастомная страница 404 работает."
else
  fail "Не найдены ожидаемые HTTP 404 и/или текст кастомной 404."
fi

section "8. Отказоустойчивость: остановить backend-1 и проверить /api"

backend1_pid_file="${RUNTIME_DIR}/backend-1.pid"

if [[ ! -f "${backend1_pid_file}" ]]; then
  fail "Не найден PID-файл backend-1: ${backend1_pid_file}. Сначала запустите run_backend.sh."
else
  backend1_pid="$(cat "${backend1_pid_file}")"

  if ! kill -0 "${backend1_pid}" 2>/dev/null; then
    fail "backend-1 PID=${backend1_pid} уже не работает; нельзя продемонстрировать падение."
  else
    echo "Остановка backend-1: PID=${backend1_pid}"
    kill "${backend1_pid}"
    rm -f "${backend1_pid_file}"

    sleep 1

    failover_headers="$(print_headers "${HTTPS_URL}/api/whoami")"
    failover_body="$("${CURL_BASE[@]}" "${HTTPS_URL}/api/whoami" || true)"

    echo "HEADERS:"
    echo "${failover_headers}"
    echo "BODY:"
    echo "${failover_body}"

    if contains "${failover_headers}" "HTTP/1.1 200" && \
       (contains "${failover_headers}" "X-Backend-ID: backend-2" || contains "${failover_body}" "\"backend_id\":\"backend-2\""); then
      pass "После остановки backend-1 nginx вернул 200 от backend-2."
    else
      fail "Failover не подтверждён: ожидался HTTP 200 от backend-2."
    fi

    echo
    echo "Ниже повторные запросы после падения backend-1:"
    for i in {1..5}; do
      echo "--- failover request ${i} ---"
      print_headers "${HTTPS_URL}/api/whoami"
    done
  fi
fi

section "Итог"

echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  echo "RESULT: PASS — Лаба 1 успешно проверена."
  exit 0
fi

echo "RESULT: FAIL — исправьте пункты с FAIL и повторите проверку."
exit 1