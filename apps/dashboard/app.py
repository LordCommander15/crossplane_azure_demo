"""
Global Warning System — Dashboard
A simple Flask app that connects to a PostgreSQL database
and displays system status.
"""

import os
import logging
from flask import Flask, render_template_string

import psycopg2

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

# ── Database configuration (populated from the Crossplane connection secret) ──
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "pgadmin")
DB_PASS = os.getenv("DB_PASSWORD", "")

TEMPLATE = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Global Warning System</title>
  <style>
    body  { font-family: sans-serif; background: #0d1117; color: #c9d1d9;
            display: flex; justify-content: center; align-items: center;
            height: 100vh; margin: 0; }
    .card { background: #161b22; border: 1px solid #30363d; border-radius: 12px;
            padding: 3rem 4rem; text-align: center; }
    h1    { color: #58a6ff; margin-bottom: 0.25rem; }
    .ok   { color: #3fb950; }
    .err  { color: #f85149; }
    small { color: #8b949e; }
  </style>
</head>
<body>
  <div class="card">
    <h1>🌍 Global Warning System</h1>
    <p>Dashboard v1.0</p>
    {% if db_ok %}
      <p class="ok">✔ Database connected ({{ db_version }})</p>
    {% else %}
      <p class="err">✖ Database unreachable: {{ db_error }}</p>
    {% endif %}
    <small>Host: {{ db_host }}:{{ db_port }}</small>
  </div>
</body>
</html>
"""


def _check_db():
    """Return (True, version_string) or (False, error_message)."""
    try:
        conn = psycopg2.connect(
            host=DB_HOST, port=DB_PORT,
            dbname=DB_NAME, user=DB_USER, password=DB_PASS,
            connect_timeout=3,
        )
        cur = conn.cursor()
        cur.execute("SELECT version();")
        version = cur.fetchone()[0].split(",")[0]
        cur.close()
        conn.close()
        return True, version
    except Exception as exc:
        return False, str(exc)


@app.route("/")
def index():
    db_ok, info = _check_db()
    return render_template_string(
        TEMPLATE,
        db_ok=db_ok,
        db_version=info if db_ok else "",
        db_error="" if db_ok else info,
        db_host=DB_HOST,
        db_port=DB_PORT,
    )


@app.route("/healthz")
def healthz():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
