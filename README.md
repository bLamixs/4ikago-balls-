# Notes Service - лабораторные работы по облачным технологиям

> Лаба 0: Flask-приложение с PostgreSQL.  
> Лаба 1: nginx, HTTPS, балансировка двух backend-инстансов и отказоустойчивость.

## Лаба 1 - быстрое развёртывание

Подробная пошаговая инструкция с командами, проверками и устранением типичных проблем находится в **[README_LAB1.md](README_LAB1.md)**. Итоговый отчёт с архитектурой и результатами - **[lab1_report.md](lab1_report.md)**.

Для запуска на Ubuntu/Debian нужны nginx, OpenSSL, `apache2-utils`, curl, Python 3 с venv и PostgreSQL. База и таблица `notes` подготавливаются по инструкции Лабы 0 ниже. Дальше:

1. Разместите проект в `/opt/notes-lab` (или замените этот путь в `nginx/sites-available/lab1.conf`).
2. Установите Python-зависимости из `backend/requirements.txt`.
3. Добавьте `notes.local` и `second.local` в `/etc/hosts`, создайте локальный TLS-сертификат и файл Basic Auth.
4. Установите конфигурацию nginx из `nginx/sites-available/` и `nginx/snippets/`, затем проверьте её командой `sudo nginx -t`.
5. Запустите два backend-инстанса и проверки:

```bash
cd /opt/notes-lab
export PYTHON_BIN="$PWD/backend/.venv/bin/python"
export DB_HOST=127.0.0.1 DB_PORT=5432 DB_NAME=notes_db
export DB_USER=notes_user DB_PASSWORD=notes_password
export ADMIN_USER=admin ADMIN_PASSWORD=lab1admin
chmod +x scripts/run_backend.sh scripts/stop_backends.sh scripts/check.sh
./scripts/run_backend.sh
./scripts/check.sh
```

Полные команды для создания сертификата и пользователя, установки nginx-конфигурации, ручной проверки балансировки и остановки окружения приведены в [инструкции по развёртыванию Лабы 1](README_LAB1.md).

---

# Notes Service - Лаба 0

Минимальный сервис заметок из трёх частей: статический фронтенд, Flask-бэкенд и отдельная база данных PostgreSQL. Через форму в браузере можно добавить заметку, а после обновления страницы она останется в списке, потому что хранится в PostgreSQL.

## Компоненты и связь

- **Frontend**: HTML, CSS и vanilla JavaScript.
- **Backend**: Python 3 + Flask, HTTP API и раздача статических файлов.
- **Database**: PostgreSQL, отдельный процесс/сервис на TCP-порту `5432`.
- **Доступ к БД**: прямой SQL через `psycopg2`, без ORM.
- **CORS не используется**: фронтенд отдаётся Flask с того же origin, что и API.

```text
[Браузер] → [Фронтенд] → HTTP → [Бэкенд :5000] → TCP → [PostgreSQL :5432]
```

Точнее, при локальном запуске браузер открывает `http://127.0.0.1:5000/`. Flask отдаёт `frontend/index.html`, `frontend/app.js` и `frontend/style.css`. JavaScript отправляет запросы по относительным адресам `/api/notes`, которые обрабатывает Flask.

## Требования

- Python 3.10 или новее.
- PostgreSQL 14 или новее.
- Утилита `psql`, обычно устанавливается вместе с PostgreSQL.
- PostgreSQL должен быть запущен как системный сервис или через `pg_ctl`.

Проверить доступность PostgreSQL можно так:

```bash
pg_isready -h 127.0.0.1 -p 5432
```

Ожидаемый результат:

```text
127.0.0.1:5432 - accepting connections
```

## Структура репозитория в ветке Lab-1

Здесь показан весь состав проекта, а не только Notes Service из Лабы 0:

```text
.
├── .env.example
├── .github/
│   └── workflows/
│       └── lab1-integration.yml
├── README.md
├── README_LAB1.md
├── admin/
│   └── index.html
├── backend/
│   ├── app.py
│   ├── init.sql
│   └── requirements.txt
├── docs/
│   └── index.html
├── frontend/
│   ├── app.js
│   ├── index.html
│   └── style.css
├── lab1_report.md
├── main.py                 # шаблон PyCharm, в лабораторной не используется
├── nginx/
│   ├── errors/
│   │   ├── 404.html
│   │   └── 50x.html
│   ├── sites-available/
│   │   └── lab1.conf
│   └── snippets/
│       └── proxy_params_lab1.conf
├── other-site/
│   └── index.html
└── scripts/
    ├── check.sh
    ├── run_backend.sh
    └── stop_backends.sh
```

### Базовое приложение Notes Service из Лабы 0

Этот фрагмент показывает только Flask-приложение, которое использует Лаба 1:

```text
backend/
├── app.py
├── init.sql
└── requirements.txt
frontend/
├── app.js
├── index.html
└── style.css
```

## Создание БД и пользователя

Выполните команды от имени PostgreSQL-суперпользователя `postgres`.

### Linux

```bash
sudo -u postgres psql
```

### Windows

Откройте `SQL Shell (psql)` из меню PostgreSQL либо выполните команду в PowerShell, если `psql` есть в `PATH`:

```powershell
psql -U postgres -h 127.0.0.1 -p 5432 -d postgres
```

В открывшейся консоли `psql` выполните:

```sql
CREATE USER notes_user WITH PASSWORD 'notes_password';
CREATE DATABASE notes_db OWNER notes_user;
\q
```

Если пользователь или база уже существуют, не выполняйте эти команды повторно: PostgreSQL вернёт ошибку `already exists`. Для учебной лабы значения логина и пароля совпадают с дефолтами приложения.

## Применение схемы БД

Из корня проекта выполните:

```bash
psql -h 127.0.0.1 -p 5432 -U notes_user -d notes_db -f backend/init.sql
```

Когда `psql` запросит пароль, введите:

```text
notes_password
```

Проверить наличие таблицы можно так:

```bash
psql -h 127.0.0.1 -p 5432 -U notes_user -d notes_db -c "\dt"
```

Должна быть видна таблица `notes`.

## Настройка переменных окружения

По умолчанию приложение использует следующие значения:

```text
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=notes_db
DB_USER=notes_user
DB_PASSWORD=notes_password
```

Они соответствуют командам из инструкции выше. Если нужны другие значения, установите переменные окружения перед запуском Flask.

### Linux / macOS

```bash
export DB_HOST=127.0.0.1
export DB_PORT=5432
export DB_NAME=notes_db
export DB_USER=notes_user
export DB_PASSWORD=notes_password
```

### PowerShell

```powershell
$env:DB_HOST = "127.0.0.1"
$env:DB_PORT = "5432"
$env:DB_NAME = "notes_db"
$env:DB_USER = "notes_user"
$env:DB_PASSWORD = "notes_password"
```

Файл `.env.example` - только пример. Приложение не читает `.env` автоматически, поэтому переменные нужно экспортировать в оболочку либо использовать значения по умолчанию.

## Установка и запуск бэкенда

Перейдите в папку `backend`:

```bash
cd backend
```

Создайте виртуальное окружение:

### Linux / macOS

```bash
python3 -m venv .venv
source .venv/bin/activate
```

### Windows PowerShell

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
```

Установите зависимости с фиксированными версиями:

```bash
pip install -r requirements.txt
```

Запустите Flask:

```bash
python app.py
```

Ожидаемый вывод содержит адрес:

```text
Running on http://127.0.0.1:5000
```

Остановить сервер можно сочетанием `Ctrl+C`.

## Открытие фронтенда

Откройте в браузере:

```text
http://127.0.0.1:5000/
```

Не запускайте `python -m http.server` в папке `frontend` для этой конфигурации: тогда фронтенд будет находиться на другом origin/порту, а API-запросы по относительному пути `/api/notes` будут уходить не в Flask.

Flask уже раздаёт статические файлы фронтенда с того же адреса, что и API. Это соответствует будущей схеме с nginx, где nginx сможет принимать запросы на одном origin и проксировать API к бэкенду.

## API

### Проверка здоровья

```bash
curl http://127.0.0.1:5000/health
```

Ответ:

```json
{"status":"ok"}
```

### Получить все заметки

```bash
curl http://127.0.0.1:5000/api/notes
```

Пример ответа:

```json
[
  {
    "id": 1,
    "text": "Первая заметка",
    "created_at": "2026-09-13T22:00:00.000000"
  }
]
```

### Создать заметку

```bash
curl -X POST http://127.0.0.1:5000/api/notes \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"Проверка PostgreSQL\"}"
```

Успешный ответ имеет HTTP-статус `201`.

Если передать пустой текст:

```bash
curl -X POST http://127.0.0.1:5000/api/notes \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"   \"}"
```

сервер вернёт HTTP `400` и JSON с сообщением об ошибке.

## Проверка работоспособности

1. Убедитесь, что PostgreSQL запущен и отвечает на `127.0.0.1:5432`.
2. Создайте пользователя `notes_user` и базу `notes_db`.
3. Примените `backend/init.sql`, чтобы создать таблицу `notes`.
4. Установите Python-зависимости и запустите `python app.py` из папки `backend`.
5. Откройте `http://127.0.0.1:5000/` в браузере.
6. Введите текст, нажмите кнопку **«Добавить»** и убедитесь, что заметка появилась в списке.
7. Обновите страницу браузера: заметка должна остаться, так как Flask читает её из PostgreSQL.

Дополнительно можно убедиться, что запись действительно находится в БД:

```bash
psql -h 127.0.0.1 -p 5432 -U notes_user -d notes_db \
  -c "SELECT id, text, created_at FROM notes ORDER BY id DESC;"
```

## Типичные проблемы

### `База данных недоступна`

Проверьте:

```bash
pg_isready -h 127.0.0.1 -p 5432
```

Также проверьте значения `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` и `DB_PASSWORD`.

### `relation "notes" does not exist`

Схема не применена. Выполните:

```bash
psql -h 127.0.0.1 -p 5432 -U notes_user -d notes_db -f backend/init.sql
```

### `password authentication failed`

Пароль пользователя PostgreSQL не совпадает с `DB_PASSWORD`. Либо исправьте переменную окружения, либо измените пароль пользователя:

```sql
ALTER USER notes_user WITH PASSWORD 'notes_password';
```

Эту SQL-команду нужно выполнить в `psql` под PostgreSQL-суперпользователем.
