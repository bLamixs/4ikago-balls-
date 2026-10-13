import logging
import os
from pathlib import Path

import psycopg2
from flask import Flask, jsonify, request, send_from_directory
from psycopg2 import OperationalError

BASE_DIR = Path(__file__).resolve().parent
FRONTEND_DIR = BASE_DIR.parent / "frontend"

app = Flask(__name__, static_folder=None)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

# Идентификатор инстанса для демонстрации балансировки
INSTANCE_ID = os.getenv("INSTANCE_ID", "unknown")


def get_db_connection():
    return psycopg2.connect(
        host=os.getenv("DB_HOST", "127.0.0.1"),
        port=os.getenv("DB_PORT", "5432"),
        dbname=os.getenv("DB_NAME", "notes_db"),
        user=os.getenv("DB_USER", "notes_user"),
        password=os.getenv("DB_PASSWORD", "notes_password"),
    )


@app.get("/health")
def health():
    response = jsonify({"status": "ok", "instance_id": INSTANCE_ID})
    response.headers["X-Backend-Instance"] = INSTANCE_ID
    return response


@app.get("/")
def index():
    return send_from_directory(FRONTEND_DIR, "index.html")


@app.get("/app.js")
def frontend_js():
    return send_from_directory(FRONTEND_DIR, "app.js")


@app.get("/style.css")
def frontend_css():
    return send_from_directory(FRONTEND_DIR, "style.css")


@app.get("/api/notes")
def get_notes():
    try:
        with get_db_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT id, text, created_at
                    FROM notes
                    ORDER BY id DESC
                    """
                )
                rows = cursor.fetchall()

        notes = [
            {
                "id": row[0],
                "text": row[1],
                "created_at": row[2].isoformat(),
                "instance_id": INSTANCE_ID,
            }
            for row in rows
        ]
        response = jsonify(notes)
        response.headers["X-Backend-Instance"] = INSTANCE_ID
        return response

    except OperationalError:
        app.logger.exception("Не удалось подключиться к PostgreSQL")
        return jsonify({"error": "База данных недоступна"}), 500
    except Exception:
        app.logger.exception("Ошибка при получении заметок")
        return jsonify({"error": "Не удалось получить заметки"}), 500


@app.post("/api/notes")
def create_note():
    data = request.get_json(silent=True)

    if not isinstance(data, dict):
        return jsonify({"error": "Ожидается JSON вида {\"text\": \"...\"}"}), 400

    text = data.get("text")

    if not isinstance(text, str) or not text.strip():
        return jsonify({"error": "Поле text не должно быть пустым"}), 400

    text = text.strip()

    try:
        with get_db_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    INSERT INTO notes (text)
                    VALUES (%s)
                    RETURNING id, text, created_at
                    """,
                    (text,),
                )
                row = cursor.fetchone()

        result = {
            "id": row[0],
            "text": row[1],
            "created_at": row[2].isoformat(),
            "instance_id": INSTANCE_ID,
        }
        response = jsonify(result)
        response.headers["X-Backend-Instance"] = INSTANCE_ID
        return response, 201

    except OperationalError:
        app.logger.exception("Не удалось подключиться к PostgreSQL")
        return jsonify({"error": "База данных недоступна"}), 500
    except Exception:
        app.logger.exception("Ошибка при сохранении заметки")
        return jsonify({"error": "Не удалось сохранить заметку"}), 500


if __name__ == "__main__":
    port = int(os.getenv("PORT", "5000"))
    app.run(host="127.0.0.1", port=port, debug=False)