# Лаба 1 — nginx перед Notes Service

> Итоговый отчёт с результатами Linux-проверки: [lab1_report.md](lab1_report.md).

## Цель

Настроить nginx как единую точку входа перед сервисом заметок из Лабы 0.

nginx должен:

- принимать HTTP на порту 80 и перенаправлять его на HTTPS;
- работать по HTTPS на порту 443 с локальным самоподписанным сертификатом;
- сам отдавать фронтенд;
- проксировать `/api/` на два Flask-инстанса;
- балансировать запросы между `backend-1` и `backend-2`;
- продолжать отдавать API, если один бэкенд остановлен;
- использовать `alias` для `/docs/`;
- поддерживать второй виртуальный хост `second.local`;
- ограничивать частоту запросов к API и отвечать `429`;
- защищать `/admin/` через Basic Authentication;
- показывать собственную 404-страницу.

## Архитектура

```text
                        HTTP :80
[Браузер/curl] ─────────────────────► [nginx]
                                           │
                                           │ 301 redirect
                                           ▼
                                      HTTPS :443
                                           │
          ┌────────────────────────────────┼───────────────────────────────┐
          │                                │                               │
          ▼                                ▼                               ▼
 [frontend: nginx root]            /docs: nginx alias              /admin: auth_basic
          │
          │ /api/*
          ▼
[upstream notes_backend_pool]
    ├── 127.0.0.1:5001 → Flask backend-1
    └── 127.0.0.1:5002 → Flask backend-2
                    │
                    ▼
            PostgreSQL :5432
```

## Предусловия

- Linux с systemd, nginx, Python 3, PostgreSQL.
- Проект лежит в `/opt/notes-lab`.
- PostgreSQL уже создан и таблица `notes` инициализированы согласно Лабе 0.
- Пользователь, запускающий Flask, имеет право читать/писать в `runtime/`.
- Запуск nginx и изменение `/etc/hosts` выполняются с `sudo`.

Если проект находится не в `/opt/notes-lab`, замените путь:

```bash
sudo sed -i 's#/opt/notes-lab#/ваш/абсолютный/путь#g' nginx/sites-available/lab1.conf
```

## 1. Установка системных пакетов

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y nginx openssl apache2-utils curl python3 python3-venv
```

Проверить nginx:

```bash
nginx -v
```

## 2. Подготовка Python

```bash
cd /opt/notes-lab/backend

python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt
deactivate
```

Если используется виртуальное окружение, запускать backend нужно с его Python:

```bash
export PYTHON_BIN=/opt/notes-lab/backend/.venv/bin/python
```

Эту переменную можно экспортировать перед `scripts/run_backend.sh`.

## 3. Hosts-записи

Добавьте локальные доменные имена:

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
127.0.0.1 notes.local
127.0.0.1 second.local
EOF
```

Проверка:

```bash
getent hosts notes.local
getent hosts second.local
```

## 4. Самоподписанный сертификат

Сертификат и пароль ниже предназначены только для локальной лабы.

```bash
sudo install -d -m 0755 /etc/nginx/lab1-certs

sudo openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /etc/nginx/lab1-certs/notes.local.key \
  -out /etc/nginx/lab1-certs/notes.local.crt \
  -subj "/C=RU/ST=Local/L=Local/O=Notes Lab/OU=Lab 1/CN=notes.local" \
  -addext "subjectAltName=DNS:notes.local,DNS:second.local,IP:127.0.0.1"

sudo chmod 600 /etc/nginx/lab1-certs/notes.local.key
sudo chmod 644 /etc/nginx/lab1-certs/notes.local.crt
```

Браузер покажет предупреждение о недоверенном сертификате — это нормально для self-signed сертификата. В curl используется ключ `-k`.

## 5. Basic Authentication для /admin

Создайте локального учебного пользователя:

```bash
sudo install -d -m 0755 /etc/nginx/lab1-auth

sudo htpasswd -c /etc/nginx/lab1-auth/notes.htpasswd admin
```

В качестве пароля для автоматического `check.sh` задайте:

```text
lab1admin
```

Права на файл:

```bash
sudo chmod 640 /etc/nginx/lab1-auth/notes.htpasswd
sudo chown root:www-data /etc/nginx/lab1-auth/notes.htpasswd
```

Если группа пользователя nginx в вашей системе не `www-data`, проверьте её:

```bash
ps -o user,group,comm -C nginx
```

И замените `www-data` на нужную группу.

Для скрипта проверок экспортируйте:

```bash
export ADMIN_USER=admin
export ADMIN_PASSWORD=lab1admin
```

## 6. Установка nginx-конфига

Скопируйте snippet с proxy-заголовками:

```bash
sudo cp /opt/notes-lab/nginx/snippets/proxy_params_lab1.conf \
  /etc/nginx/snippets/proxy_params_lab1.conf
```

Скопируйте конфиг сайта:

```bash
sudo cp /opt/notes-lab/nginx/sites-available/lab1.conf \
  /etc/nginx/sites-available/lab1.conf
```

Отключите стандартный сайт, если он занимает 80/443:

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

Создайте символическую ссылку:

```bash
sudo ln -sfn /etc/nginx/sites-available/lab1.conf \
  /etc/nginx/sites-enabled/lab1.conf
```

Проверьте синтаксис до reload:

```bash
sudo nginx -t
```

Ожидаемо:

```text
nginx: configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

После успешной проверки примените конфигурацию:

```bash
sudo systemctl reload nginx
sudo systemctl enable --now nginx
```

Проверьте, что порты заняты nginx:

```bash
sudo ss -ltnp | grep -E ':(80|443)\b'
```

## 7. Запуск двух Flask-бэкендов

Перейдите в каталог проекта:

```bash
cd /opt/notes-lab
```

Если создано виртуальное окружение:

```bash
export PYTHON_BIN=/opt/notes-lab/backend/.venv/bin/python
```

Задайте подключение к PostgreSQL:

```bash
export DB_HOST=127.0.0.1
export DB_PORT=5432
export DB_NAME=notes_db
export DB_USER=notes_user
export DB_PASSWORD=notes_password
```

Сделайте скрипты исполняемыми:

```bash
chmod +x scripts/run_backend.sh
chmod +x scripts/stop_backends.sh
chmod +x scripts/check.sh
```

Запустите обе копии:

```bash
./scripts/run_backend.sh
```

Проверьте процессы и порты:

```bash
ps aux | grep '[p]ython.*app.py'
ss -ltnp | grep -E ':(5001|5002)\b'
```

Прямые проверки:

```bash
curl http://127.0.0.1:5001/api/whoami
curl http://127.0.0.1:5002/api/whoami
```

Ожидаемо:

```json
{"backend_id":"backend-1"}
```

и:

```json
{"backend_id":"backend-2"}
```

## 8. Ручная проверка nginx

HTTP redirect:

```bash
curl -I http://notes.local/
```

Ожидаемый фрагмент:

```text
HTTP/1.1 301 Moved Permanently
Location: https://notes.local/
```

Балансировка:

```bash
for i in {1..8}; do
  curl -skI https://notes.local/api/whoami | grep -iE 'HTTP/|X-Backend-ID'
  sleep 0.3
done
```

В ответах должны встречаться оба заголовка:

```text
X-Backend-ID: backend-1
X-Backend-ID: backend-2
```

Alias:

```bash
curl -sk https://notes.local/docs/
```

Admin без пароля:

```bash
curl -skI https://notes.local/admin/
```

Ожидается:

```text
HTTP/1.1 401 Unauthorized
```

Admin с паролем:

```bash
curl -skI -u admin:lab1admin https://notes.local/admin/
```

Ожидается:

```text
HTTP/1.1 200 OK
```

Второй виртуальный хост:

```bash
curl -sk https://second.local/
```

Должен быть текст:

```text
Second Local Project
```

Неизвестный Host:

```bash
curl -skI https://127.0.0.1/ -H 'Host: unknown.local'
```

Ожидается обрыв соединения (`444`) либо отсутствие HTTP-ответа, но не `200` с интерфейсом заметок.

Кастомная 404:

```bash
curl -sk https://notes.local/no-such-page
```

Должен быть текст:

```text
404 — Страница не найдена
```

Rate limit:

```bash
seq 1 40 | xargs -P 20 -I {} curl -sk -o /dev/null -w '%{http_code}\n' https://notes.local/api/whoami
```

Среди кодов должен появиться `429`.

## 9. Автоматическая проверка

```bash
cd /opt/notes-lab

export ADMIN_USER=admin
export ADMIN_PASSWORD=lab1admin

./scripts/check.sh
```

Скрипт:

1. проверяет HTTP → HTTPS 301;
2. отправляет серию запросов к `/api/whoami` и ищет оба backend ID;
3. проверяет 401 на `/admin`;
4. проверяет 200 на `/admin` с Basic Auth;
5. создаёт флуд запросов и ищет 429;
6. проверяет `second.local` и неизвестный Host;
7. проверяет свою 404;
8. останавливает `backend-1` и подтверждает, что nginx вернул 200 от `backend-2`;
9. в `trap` запускает оба backend-процесса обратно.

## 10. Демонстрация отказоустойчивости вручную

Перед началом оба инстанса должны работать:

```bash
./scripts/run_backend.sh
```

Убедитесь в балансировке:

```bash
for i in {1..6}; do
  curl -skI https://notes.local/api/whoami | grep -iE 'HTTP/|X-Backend-ID'
  sleep 0.3
done
```

Остановите первый процесс:

```bash
kill "$(cat runtime/backend-1.pid)"
rm -f runtime/backend-1.pid
```

Проверьте, что API продолжает отвечать:

```bash
for i in {1..5}; do
  curl -skI https://notes.local/api/whoami | grep -iE 'HTTP/|X-Backend-ID'
  sleep 0.3
done
```

Ожидаемый результат: каждый ответ имеет `HTTP/1.1 200 OK` и `X-Backend-ID: backend-2`.

В error log nginx можно увидеть, что порт 5001 недоступен:

```bash
sudo tail -f /var/log/nginx/notes-lab-error.log
```

Восстановите первый процесс:

```bash
./scripts/run_backend.sh
```

## Остановка окружения

Остановить Flask-инстансы:

```bash
./scripts/stop_backends.sh
```

Остановить nginx:

```bash
sudo systemctl stop nginx
```

## Материалы лабораторной

- [Итоговый отчёт](lab1_report.md) — цель, архитектура, ход работы и фактические результаты автоматической проверки.
- [Полная инструкция по развёртыванию](README_LAB1.md) — команды установки, настройки, запуска и остановки окружения.
